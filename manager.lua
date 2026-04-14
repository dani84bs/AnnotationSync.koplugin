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

local SyncManager = {}

function SyncManager:new(plugin)
    local o = {
        plugin = plugin,
        page_turn_counter = 0,
        last_page = 0,
        is_syncing = false,
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

function SyncManager:onPageUpdate(page_pos)
    if not self.plugin.settings.progress_sync then return end
    logger.dbg("AnnotationSync: onPageUpdate event received")

    local current_page = self.plugin.ui:getCurrentPage()
    if current_page ~= self.last_page then
        self.page_turn_counter = self.page_turn_counter + 1
        self.last_page = current_page
    end

    if self.page_turn_counter >= self.plugin.settings.progress_sync_interval then
        self.page_turn_counter = 0
        self:syncProgress()
    end
end

function SyncManager:syncProgress()
    if self.is_syncing then return end
    self.is_syncing = true

    if not NetworkMgr:isConnected() then
        logger.info("AnnotationSync: network is disconnected, skipping progress sync")
        self.is_syncing = false
        return
    end

    logger.info("AnnotationSync: starting progress sync")

    local document = self.plugin.ui and self.plugin.ui.document
    if not document then
        self.is_syncing = false
        return
    end

    local file = document.file
    if not file then
        self.is_syncing = false
        return
    end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        self.is_syncing = false
        return
    end

    -- Ensure the local sidecar directory exists
    if not lfs.attributes(sdr_dir, "mode") then
        logger.info("AnnotationSync: creating missing sidecar directory: " .. sdr_dir)
        os.execute("mkdir -p " .. sdr_dir)
    end

    local filename = self:_getProgressFilename(file)
    local json_path = sdr_dir .. "/" .. filename

    local device_id = Device.model or "unknown"
    local page = self.plugin.ui:getCurrentPage()
    local total = 0
    if self.plugin.ui.paging then
        total = self.plugin.ui.paging.number_of_pages or 0
    end
    if total <= 0 and self.plugin.ui.document then
        total = self.plugin.ui.document:getPageCount() or 0
    end

    local percentage = 0
    if total > 0 then
        percentage = page / total
    elseif self.plugin.ui.paging then
        percentage = self.plugin.ui.paging:getLastPercent() or 0
    end

    local current_progress = {
        page = page,
        percentage = percentage,
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
                timestamp = local_data.timestamp,
            }
        }
    end

    local_data[device_id] = current_progress

    local f = io.open(json_path, "w")
    if f then
        f:write(json.encode(local_data))
        f:close()

        logger.dbg("AnnotationSync: pushing progress to remote: " .. json_path)
        UIManager:scheduleIn(0.1, function()
            remote.push_progress(json_path, function(success)
                self.is_syncing = false
                if success then
                    logger.dbg("AnnotationSync: progress sync successful")
                else
                    logger.warn("AnnotationSync: progress sync failed")
                end
            end)
        end)
    else
        logger.warn("AnnotationSync: failed to write progress JSON: " .. json_path)
        self.is_syncing = false
    end
end

function SyncManager:pullProgress()
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

    utils.show_msg(_("Fetching remote progress..."))
    remote.pull_progress(json_path, function(success, merged_data)
        if success and merged_data then
            self:showJumpMenu(merged_data)
        else
            utils.show_msg(_("Failed to fetch remote progress"))
        end
    end)
end

function SyncManager:showJumpMenu(progress_map)
    local Menu = require("ui/widget/menu")
    local menu_items = {}

    local device_id = Device.model or "unknown"

    -- Sort devices by timestamp descending
    local devices = {}
    for dev_id, data in pairs(progress_map) do
        table.insert(devices, { id = dev_id, data = data })
    end
    table.sort(devices, function(a, b)
        if not a.data.timestamp then return false end
        if not b.data.timestamp then return true end
        return a.data.timestamp > b.data.timestamp
    end)

    for idx, dev in ipairs(devices) do
        local is_current = (dev.id == device_id)
        local percentage = (dev.data.percentage or 0) * 100
        local text = string.format("%s: Page %d (%d%%)",
            dev.id, dev.data.page or 0, math.floor(percentage + 0.5))
        if is_current then
            text = text .. " " .. _("(this device)")
        end

        table.insert(menu_items, {
            text = text,
            sub_text = dev.data.timestamp,
            callback = function()
                self.plugin.ui:handleEvent(Event:new("GotoPage", dev.data.page))
                UIManager:broadcastEvent(Event:new("JumpToPage", dev.data.page))
                utils.show_msg(T(_("Jumped to page %1 from %2"), dev.data.page, dev.id))
            end
        })
    end

    if #menu_items == 0 then
        utils.show_msg(_("No remote progress found."))
        return
    end

    local jump_menu = Menu:new{
        title = _("Jump to device progress"),
        item_table = menu_items,
    }
    UIManager:show(jump_menu)
end

-- Sync all changed documents listed in changed_documents.lua
function SyncManager:syncAllChangedDocuments()
    local total, changed_docs = self:getPendingChangedDocuments()
    if total == 0 then
        utils.show_msg("No changed documents to sync.")
        return
    end
    local count = 0
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
            elseif not ok then
                logger.warn("AnnotationSync: syncDocument CRASHED for " .. file .. ": " .. tostring(success))
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
            end
        end
    end
    if count == 0 then
        utils.show_msg("Unable to sync modified documents: " .. total)
    else
        self:updateLastSync("Sync All")
        utils.show_msg("Successfully synced modified documents: " .. count)
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
        os.execute("mkdir -p " .. sdr_dir)
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
    local f = io.open(track_path, "w")
    if f then
        f:write("return ", self:_serialize_table(changed_docs), "\n")
        f:close()
    else
        logger.warn("AnnotationSync: Failed to open changed documents file: " .. track_path)
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
        return (cmp or 0) > 0
    end)

    return deleted
end

-- Helper to get a document object by file path
function SyncManager:getDocumentByFile(file)
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

return SyncManager