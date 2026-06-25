local DocumentRegistry = require("document/documentregistry")
local DataStorage = require("datastorage")
local Device = require("device")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local logger = require("logger")
local json = require("json")
local _ = require("gettext")
local T = require("ffi/util").template
local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local lfs = require("libs/libkoreader-lfs")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")
local menus = require("menus")

local SyncManager = {}

function SyncManager:new(plugin)
    local o = {
        plugin = plugin,
        page_turn_counter = 0,
        last_page = 0,
        is_syncing = false,
        sync_progress_scheduled = false,
        has_pending_sync = false,
    }
    o.sync_progress_task = function()
        o.sync_progress_scheduled = false
        o:syncProgress()
    end
    setmetatable(o, self)
    self.__index = self
    return o
end

function SyncManager:onPageUpdate(page_pos)
    if not (self.plugin.ui.cloudstorage or self.plugin.has_syncservice) or not self.plugin.settings.progress_sync then return end
    logger.dbg("AnnotationSync: onPageUpdate event received")

    local current_page = self.plugin.ui:getCurrentPage()
    if current_page ~= self.last_page then
        self.page_turn_counter = self.page_turn_counter + 1
        self.last_page = current_page
    end

    if self.page_turn_counter >= self.plugin.settings.progress_sync_interval then
        self.page_turn_counter = 0
        if self.sync_progress_scheduled then
            UIManager:unschedule(self.sync_progress_task)
        end
        UIManager:scheduleIn(3, self.sync_progress_task)
        self.sync_progress_scheduled = true
    end
end

function SyncManager:onCloseDocument()
    if self.sync_progress_scheduled then
        UIManager:unschedule(self.sync_progress_task)
        self.sync_progress_scheduled = false
        self:syncProgress()
    end
end

function SyncManager:onSuspend()
    if self.sync_progress_scheduled then
        UIManager:unschedule(self.sync_progress_task)
        self.sync_progress_scheduled = false
        self:syncProgress()
    end
end

function SyncManager:checkPendingSync()
    if self.has_pending_sync then
        self.has_pending_sync = false
        UIManager:nextTick(function()
            self:syncProgress()
        end)
    end
end

function SyncManager:getDeviceName()
    if self.plugin.settings.device_name and self.plugin.settings.device_name ~= "" then
        return self.plugin.settings.device_name
    end
    return Device.model or "unknown"
end

function SyncManager:saveLocalProgress(document, json_path)
    local file = document.file
    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return false end

    -- Ensure the local sidecar directory exists
    if not lfs.attributes(sdr_dir, "mode") then
        logger.info("AnnotationSync: creating missing sidecar directory: " .. sdr_dir)
        util.makePath(sdr_dir)
    end

    local device_id = self:getDeviceName()
    local page = self.plugin.ui:getCurrentPage()
    local total = 0
    if self.plugin.ui.paging then
        total = self.plugin.ui.paging.number_of_pages or 0
    end
    if total <= 0 and self.plugin.ui.document then
        total = self.plugin.ui.document:getPageCount() or 0
    end

    local percentage = 0
    local paging_module = self.plugin.ui.paging or self.plugin.ui.rolling
    if paging_module then
        percentage = paging_module:getLastPercent() or 0
    end

    if percentage <= 0 and total > 0 then
        percentage = page / total
    end

    local pos = paging_module and paging_module.getLastProgress and paging_module:getLastProgress()
    if type(pos) == "string" and self.plugin.settings.progress_sync_last_word then
        local view = self.plugin.ui.view
        if view and view.view_mode == "page" then
            local doc = self.plugin.ui.document
            if doc and doc.isXPointerInDocument and doc:isXPointerInDocument(pos) then
                if doc.getPageXPointer and doc.getPrevVisibleWordStart then
                    local next_page_xp = doc:getPageXPointer(page + 1)
                    if next_page_xp then
                        local xp = next_page_xp
                        for i = 1, 3 do
                            local prev_xp = doc:getPrevVisibleWordStart(xp)
                            if prev_xp then
                                xp = prev_xp
                            else
                                break
                            end
                        end
                        if xp ~= next_page_xp then
                            pos = xp
                        end
                    end
                end
            end
        end
    end

    local current_progress = {
        page = page,
        percentage = percentage,
        pos = pos,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    }

    local local_data = utils.read_json(json_path) or {}
    -- Normalize if old format
    if local_data.device and local_data.page then
        local old_device = local_data.device
        local_data = {
            [old_device] = {
                page = local_data.page,
                percentage = local_data.percentage,
                pos = local_data.pos,
                timestamp = local_data.timestamp,
            }
        }
    end

    local_data[device_id] = current_progress

    return util.writeToFile(json.encode(local_data), json_path, true, false, true)
end

function SyncManager:syncProgress(on_complete)
    if self.is_syncing then
        self.has_pending_sync = true
        if on_complete then
            on_complete(false)
        end
        return
    end
    self.is_syncing = true
    self.has_pending_sync = false

    if not NetworkMgr:isConnected() then
        logger.info("AnnotationSync: network is disconnected, skipping progress sync")
        self.is_syncing = false
        self:checkPendingSync()
        if on_complete then
            on_complete(false)
        end
        return
    end

    logger.info("AnnotationSync: starting progress sync")

    local document = self.plugin.ui and self.plugin.ui.document
    if not document then
        self.is_syncing = false
        self:checkPendingSync()
        if on_complete then
            on_complete(false)
        end
        return
    end

    local file = document.file
    if not file then
        self.is_syncing = false
        self:checkPendingSync()
        if on_complete then
            on_complete(false)
        end
        return
    end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        self.is_syncing = false
        self:checkPendingSync()
        if on_complete then
            on_complete(false)
        end
        return
    end

    local filename = self:_getProgressFilename(file)
    local json_path = sdr_dir .. "/" .. filename

    if self:saveLocalProgress(document, json_path) then
        logger.dbg("AnnotationSync: pushing progress to remote: " .. json_path)
        UIManager:scheduleIn(0.1, function()
            remote.push_progress_bg(self.plugin, json_path, function(success)
                self.is_syncing = false
                if success then
                    logger.dbg("AnnotationSync: progress sync successful")
                else
                    logger.warn("AnnotationSync: progress sync failed")
                end
                if on_complete then
                    on_complete(success)
                end
                self:checkPendingSync()
            end)
        end)
    else
        logger.warn("AnnotationSync: failed to write progress JSON: " .. json_path)
        self.is_syncing = false
        self:checkPendingSync()
        if on_complete then
            on_complete(false)
        end
    end
end

function SyncManager:pullProgress()
    if not (self.plugin.ui.cloudstorage or self.plugin.has_syncservice) then
        utils.show_msg(_("Reading progress sync is not supported on this version of KOReader."))
        return
    end

    if not NetworkMgr:isConnected() then
        utils.show_msg(_("Network is disconnected, cannot pull progress"))
        return
    end

    local document = self.plugin.ui and self.plugin.ui.document
    if not document then return end

    local file = document.file
    if not file then return end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return end

    local filename = self:_getProgressFilename(file)
    local json_path = sdr_dir .. "/" .. filename

    -- Ensure local progress is saved so local file and sidecar dir exist before pulling
    self:saveLocalProgress(document, json_path)

    utils.show_msg(_("Fetching remote progress..."))
    remote.pull_progress(self.plugin, json_path, function(success, merged_data)
        if success and merged_data then
            menus.show_jump_menu(self.plugin, merged_data)
        else
            utils.show_msg(_("Failed to fetch remote progress"))
        end
    end)
end

-- Sync all changed documents listed in changed_documents.lua
function SyncManager:syncAllChangedDocuments()
    local total, changed_docs = self:getPendingChangedDocuments()
    if total == 0 then
        utils.show_msg("No changed documents to sync.")
        return
    end
    local count = 0
    local failed_files = {}
    local ui_document = self.plugin.ui and self.plugin.ui.document
    for file, _ in pairs(changed_docs) do
        -- Try to get a document object for this file, open if needed
        local document = self:getDocumentByFile(file)
        if document then
            logger.info("AnnotationSync: syncing document: " .. file)
            local is_temporary = (document ~= ui_document)
            local ok, success = pcall(self.syncDocument, self, document, false)
            if ok and success then
                count = count + 1
            else
                if not ok then
                    logger.warn("AnnotationSync: syncDocument CRASHED for " .. file .. ": " .. tostring(success))
                end
                table.insert(failed_files, file)
            end

            if is_temporary then
                logger.info("AnnotationSync: closing temporary document: " .. file)
                document:close()
            end
        else
            -- Check if file still exists
            if not util.fileExists(file) then
                logger.warn("AnnotationSync: file missing, removing from sync list: " .. file)
                self:removeFromChangedDocumentsFileByPath(file)
            else
                logger.warn("AnnotationSync: could not open document for sync: " .. file)
                table.insert(failed_files, file)
            end
        end
    end
    if count == 0 then
        utils.show_msg("Unable to sync modified documents: " .. total)
    else
        self:updateLastSync("Sync All")
        utils.show_msg("Successfully synced modified documents: " .. count)
    end

    if #failed_files > 0 then
        local filenames = {}
        for _, file in ipairs(failed_files) do
            table.insert(filenames, file:match("([^/]+)$") or file)
        end
        local ConfirmBox = require("ui/widget/confirmbox")
        local list_str = "- " .. table.concat(filenames, "\n- ")
        UIManager:nextTick(function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Unable to sync the following document(s):\n%1\n\nWould you like to open the pending documents manager?"), list_str),
                type = "yesno",
                ok_text = _("Open Manager"),
                ok_callback = function()
                    menus.show_pending_documents(self.plugin)
                end,
                cancel_text = _("Close"),
            })
        end)
    end
end

-- Orchestrates the sync process for a single document
function SyncManager:syncDocument(document, is_manual)
    local file = document and document.file
    if not file then return false end

    self:_flushSettings()
    logger.dbg("AnnotationSync: syncing document: " .. file)

    local json_path = self:writeAnnotationsJSON(document)
    if not json_path then return false end

    logger.dbg("AnnotationSync: remote sync of " .. json_path .. " (force=" .. tostring(is_manual) .. ")")
    local sync_success = false
    remote.sync_annotations(self.plugin, document, json_path, function(success, merged_list)
        sync_success = success
        self:_onSyncComplete(document, success, merged_list)
    end, is_manual)
    return sync_success
end

-- Refreshes the local sync JSON file with latest memory/sidecar state
function SyncManager:writeAnnotationsJSON(document)
    local file = document and document.file
    if not file then return false end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return false end

    -- Fix for Issue #34: Ensure the local sidecar directory exists
    if not lfs.attributes(sdr_dir, "mode") then
        logger.info("AnnotationSync: creating missing sidecar directory: " .. sdr_dir)
        util.makePath(sdr_dir)
    end

    local filename = self:_getAnnotationFilename(file)
    return annotations.write_annotations_json(document, self:getAnnotationsForDocument(document), sdr_dir, filename)
end

function SyncManager:changedDocumentsFile()
    return DataStorage:getDataDir() .. "/changed_documents.lua"
end

function SyncManager:getPendingChangedDocuments()
    local count = 0
    local track_path = self:changedDocumentsFile()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" then
        for _ in pairs(changed_docs) do count = count + 1 end
    end
    return count, changed_docs
end

function SyncManager:hasPendingChangedDocuments()
    local count, _ = self:getPendingChangedDocuments()
    return count > 0
end

function SyncManager:addToChangedDocumentsFile(file)
    local track_path = self:changedDocumentsFile()
    -- Load existing table or create new
    local changed_docs = {}
    local ok, loaded = pcall(dofile, track_path)
    if ok and type(loaded) == "table" then
        changed_docs = loaded
    end
    if file and type(file) == "string" then
        changed_docs[file] = true
        self:writeChangedDocumentsFile(changed_docs)
    end
end

function SyncManager:removeFromChangedDocumentsFile(document)
    local file = document and document.file
    self:removeFromChangedDocumentsFileByPath(file)
end

function SyncManager:removeFromChangedDocumentsFileByPath(file)
    if not file then return end
    local track_path = self:changedDocumentsFile()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" and changed_docs[file] then
        changed_docs[file] = nil
        self:writeChangedDocumentsFile(changed_docs)
    end
end

function SyncManager:writeChangedDocumentsFile(changed_docs)
    local track_path = self:changedDocumentsFile()
    local ok, err = util.writeToFile(self:_serialize_table(changed_docs), track_path, true, true, true)
    if not ok then
        logger.warn("AnnotationSync: Failed to write changed documents file: " .. track_path .. " (" .. tostring(err) .. ")")
    end
end

-- Get annotations associated with given document
function SyncManager:getAnnotationsForDocument(document)
    -- Handle active document
    if document == self.plugin.ui.document and self.plugin.ui.annotation and self.plugin.ui.annotation.annotations then
        return self.plugin.ui.annotation.annotations
    end
    -- Handle inactive document
    local annotation_sidecar = docsettings:open(document.file)
    local result = annotation_sidecar:readSetting("annotations")
    return result or {}
end

-- Get only annotations marked as deleted in the local sync JSON
function SyncManager:getDeletedAnnotations(document)
    local file = document and document.file
    if not file then return {} end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return {} end

    local filename = self:_getAnnotationFilename(file)
    local json_path = sdr_dir .. "/" .. filename

    local map = utils.read_json(json_path)
    if not map then return {} end

    local deleted = {}
    for _, v in pairs(map) do
        if v.deleted then
            table.insert(deleted, v)
        end
    end

    table.sort(deleted, function(a, b)
        local cmp = annotations.compare_positions(a.page, b.page, document)
        return (cmp or 0) < 0
    end)

    return deleted
end

-- Helper to get a document object by file path
function SyncManager:getDocumentByFile(file)
    if not file or not util.fileExists(file) then
        return nil
    end
    -- If the current document is available, return it if it matches.
    local ui_document = self.plugin.ui and self.plugin.ui.document
    if ui_document and ui_document.file == file then
        return ui_document
    end
    -- Otherwise open the document with the correct provider in order to use
    -- its `comparePositions()` function.
    local document
    local provider = DocumentRegistry:getProvider(file)
    if provider then
        logger.dbg("AnnotationSync: provider for " .. file .. ": " .. provider.provider)
        document = DocumentRegistry:openDocument(file, provider)
        -- A document provided by crengine must be rendered in order to use
        -- any functions that rely on XPointers.
        if provider.provider == "crengine" then
            if document then
                logger.dbg("AnnotationSync: rendering: " .. file)
                document:render()
            end
        end
    end
    return document
end

function SyncManager:updateLastSync(descriptor)
    local parenthetical = ""
    if descriptor and type(descriptor) == "string" then
        parenthetical = " (" .. descriptor .. ")"
    end
    self.plugin.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. parenthetical
    logger.dbg("AnnotationSync: updateLastSync: updated at " .. self.plugin.settings.last_sync)
end

function SyncManager:_flushSettings()
    UIManager:broadcastEvent(Event:new("FlushSettings"))
end

function SyncManager:_getAnnotationFilename(file)
    if self.plugin.settings.use_filename then
        local filename = file:match("([^/]+)$") or file
        return filename .. ".json"
    end
    local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
    return hash .. ".json"
end

function SyncManager:_getProgressFilename(file)
    if self.plugin.settings.use_filename then
        local filename = file:match("([^/]+)$") or file
        return filename .. ".progress.json"
    end
    local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
    return hash .. ".progress.json"
end

function SyncManager:_onSyncComplete(document, success, merged_list)
    if success then
        if merged_list then
            self.plugin:applySyncedAnnotations(document, merged_list)
        end
        self:removeFromChangedDocumentsFile(document)
    else
        logger.warn("AnnotationSync: sync failed for " .. (document.file or "unknown") .. ", keeping in changed list")
    end
end

-- Helper to serialize a Lua table as code
function SyncManager:_serialize_table(tbl)
    local result = "{\n"
    for k, v in pairs(tbl) do
        result = result .. string.format("  [%q] = %s,\n", k, tostring(v))
    end
    result = result .. "}"
    return result
end

function SyncManager:getSelectedSettingsWithValues()
    local selected = self.plugin.settings.selected_settings or {}
    local has_any = false
    for _, _ in pairs(selected) do
        has_any = true
        break
    end
    if not has_any then
        return nil
    end

    -- Load active reader settings
    local active_reader_path = DataStorage:getDataDir() .. "/settings.reader.lua"
    local ok_a, active_reader = pcall(dofile, active_reader_path)
    if not ok_a or type(active_reader) ~= "table" then
        active_reader = {}
    end

    -- Load active defaults settings
    local active_defaults_path = DataStorage:getDataDir() .. "/defaults.custom.lua"
    local ok_ad, active_defaults = pcall(dofile, active_defaults_path)
    if not ok_ad or type(active_defaults) ~= "table" then
        active_defaults = {}
    end

    -- Cache for loaded settings files in settings/ directory
    local settings_cache = {}

    local result = {}
    for key, is_selected in pairs(selected) do
        if is_selected then
            local domain, full_key = key:match("^([^:]+):(.*)$")
            if domain and full_key then
                local val
                if domain == "reader" then
                    val = utils.get_nested_value(active_reader, full_key)
                elseif domain == "defaults" then
                    val = utils.get_nested_value(active_defaults, full_key)
                elseif domain:match("^settings/") then
                    local settings_name = domain:sub(10)
                    if settings_cache[settings_name] == nil then
                        local filepath = DataStorage:getSettingsDir() .. "/" .. settings_name .. ".lua"
                        local ok_s, a_tbl = pcall(dofile, filepath)
                        if ok_s and type(a_tbl) == "table" then
                            settings_cache[settings_name] = a_tbl
                        else
                            settings_cache[settings_name] = false
                        end
                    end
                    local tbl = settings_cache[settings_name]
                    if tbl then
                        val = utils.get_nested_value(tbl, full_key)
                    end
                end
                result[key] = val
            end
        end
    end

    return result
end

function SyncManager:pushSettings()
    local selected_values = self:getSelectedSettingsWithValues()
    if not selected_values then
        utils.show_msg(_("No settings are selected. Please select settings to sync in 'Show changed settings'."))
        return
    end

    local device_id = self:getDeviceName()
    local local_data = {
        [device_id] = {
            settings = selected_values,
            timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        }
    }

    local json_path = DataStorage:getDataDir() .. "/settings_sync.json"
    local ok, err = util.writeToFile(json.encode(local_data), json_path, true, false, true)
    if not ok then
        logger.warn("AnnotationSync: failed to write settings JSON: " .. json_path .. " (" .. tostring(err) .. ")")
        utils.show_msg(_("Failed to write settings to local storage."))
        return
    end

    logger.dbg("AnnotationSync: pushing settings to remote: " .. json_path)
    utils.show_msg(_("Pushing settings to cloud..."))
    remote.sync_settings(self.plugin, json_path, function(success)
        if success then
            logger.dbg("AnnotationSync: settings push successful")
        else
            logger.warn("AnnotationSync: settings push failed")
        end
    end)
end

local function values_differ(v1, v2)
    if type(v1) ~= type(v2) then
        return true
    end
    if type(v1) == "table" then
        return json.encode(v1) ~= json.encode(v2)
    end
    return v1 ~= v2
end

function SyncManager:getLocalSettingValue(key, caches)
    caches = caches or {}
    local domain, full_key = key:match("^([^:]+):(.*)$")
    if not domain or not full_key then return nil end

    if domain == "reader" then
        if caches.reader == nil then
            local active_reader_path = DataStorage:getDataDir() .. "/settings.reader.lua"
            local ok, active_reader = pcall(dofile, active_reader_path)
            caches.reader = ok and active_reader or {}
        end
        return utils.get_nested_value(caches.reader, full_key)
    elseif domain == "defaults" then
        if caches.defaults == nil then
            local active_defaults_path = DataStorage:getDataDir() .. "/defaults.custom.lua"
            local ok, active_defaults = pcall(dofile, active_defaults_path)
            caches.defaults = ok and active_defaults or {}
        end
        return utils.get_nested_value(caches.defaults, full_key)
    elseif domain:match("^settings/") then
        local settings_name = domain:sub(10)
        if caches[settings_name] == nil then
            local filepath = DataStorage:getSettingsDir() .. "/" .. settings_name .. ".lua"
            local ok, a_tbl = pcall(dofile, filepath)
            caches[settings_name] = ok and a_tbl or false
        end
        local tbl = caches[settings_name]
        if tbl then
            return utils.get_nested_value(tbl, full_key)
        end
    end
    return nil
end

local function save_nested_setting(settings_obj, parts, value)
    if #parts == 1 then
        settings_obj:saveSetting(parts[1], value)
    else
        local top_key = parts[1]
        local top_val = settings_obj:readSetting(top_key)
        if type(top_val) ~= "table" then
            top_val = {}
        end
        local new_tbl = util.tableDeepCopy(top_val)
        local current = new_tbl
        for i = 2, #parts - 1 do
            local part = parts[i]
            if type(current[part]) ~= "table" then
                current[part] = {}
            end
            current = current[part]
        end
        current[parts[#parts]] = value
        settings_obj:saveSetting(top_key, new_tbl)
    end
    settings_obj:flush()
end

function SyncManager:writeLocalSettingValue(key, value)
    local domain, full_key = key:match("^([^:]+):(.*)$")
    if not domain or not full_key then return false end

    local LuaSettings = require("luasettings")
    local parts = {}
    for part in string.gmatch(full_key, "([^%.]+)") do
        table.insert(parts, part)
    end

    if domain == "reader" then
        save_nested_setting(G_reader_settings, parts, value)

        local filepath = DataStorage:getDataDir() .. "/settings.reader.lua"
        local settings_obj = LuaSettings:open(filepath)
        save_nested_setting(settings_obj, parts, value)
        return true
    elseif domain == "defaults" then
        local filepath = DataStorage:getDataDir() .. "/defaults.custom.lua"
        local settings_obj = LuaSettings:open(filepath)
        save_nested_setting(settings_obj, parts, value)
        return true
    elseif domain:match("^settings/") then
        local settings_name = domain:sub(10)
        local filepath = DataStorage:getSettingsDir() .. "/" .. settings_name .. ".lua"
        local settings_obj = LuaSettings:open(filepath)
        save_nested_setting(settings_obj, parts, value)
        return true
    end
    return false
end


function SyncManager:pullSettings()
    if not NetworkMgr:isConnected() then
        utils.show_msg(_("Network is disconnected, cannot pull settings"))
        return
    end

    local json_path = DataStorage:getDataDir() .. "/settings_sync.json"
    
    utils.show_msg(_("Fetching settings from cloud..."))
    remote.sync_settings(self.plugin, json_path, function(success, merged_data)
        if success and merged_data then
            menus.show_devices_menu(self.plugin, merged_data)
        else
            utils.show_msg(_("Failed to fetch settings from cloud"))
        end
    end)
end

return SyncManager