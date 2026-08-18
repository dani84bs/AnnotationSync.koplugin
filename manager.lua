local DocumentRegistry = require("document/documentregistry")
local NetworkMgr = require("ui/network/manager")
local util = require("util")
local logger = require("logger")
local json = require("json")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local lfs = require("libs/libkoreader-lfs")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")
local menus = require("menus")
local changed_documents = require("changed_documents")
local library_scan = require("library_scan")

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

    local document = self.plugin.ui.document
    if document and document.file then
        local dir = ffiUtil.dirname(document.file)
        if utils.is_path_excluded(dir, self.plugin.settings.progress_sync_excluded_dirs) then return end
    end

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

function SyncManager:saveLocalProgress(document, json_path)
    local file = document.file
    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return false end

    -- Ensure the local sidecar directory exists
    if not lfs.attributes(sdr_dir, "mode") then
        logger.info("AnnotationSync: creating missing sidecar directory: " .. sdr_dir)
        util.makePath(sdr_dir)
    end

    local device_id = utils.get_device_name(self.plugin)
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

    local document, json_path = self:_getCurrentDocumentAndProgressPath()
    if not document then
        self.is_syncing = false
        self:checkPendingSync()
        if on_complete then
            on_complete(false)
        end
        return
    end

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

    local document, json_path = self:_getCurrentDocumentAndProgressPath()
    if not document then return end

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

function SyncManager:_getCurrentDocumentAndProgressPath()
    local document = self.plugin.ui and self.plugin.ui.document
    if not document then return nil end

    local file = document.file
    if not file then return nil end

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return nil end

    local filename = self:_getProgressFilename(file)
    return document, sdr_dir .. "/" .. filename
end

function SyncManager:purgeDevicePrompt()
    if not (self.plugin.ui.cloudstorage or self.plugin.has_syncservice) then
        utils.show_msg(_("Reading progress sync is not supported on this version of KOReader."))
        return
    end

    local document, json_path = self:_getCurrentDocumentAndProgressPath()
    if not document then return end

    self:saveLocalProgress(document, json_path)
    local progress_map = utils.read_json(json_path) or {}

    local purged_lookup = {}
    for _, name in ipairs(self.plugin.settings.purged_devices or {}) do
        purged_lookup[name] = true
    end
    local purgeable_map = {}
    for device_id, data in pairs(progress_map) do
        if not purged_lookup[device_id] then
            purgeable_map[device_id] = data
        end
    end

    menus.show_purge_device_menu(self.plugin, purgeable_map, function(device_name)
        self:purgeDevice(device_name)
    end)
end

function SyncManager:purgeDevice(device_name, on_complete)
    self.plugin.settings.purged_devices = self.plugin.settings.purged_devices or {}
    local already_purged = false
    for _, name in ipairs(self.plugin.settings.purged_devices) do
        if name == device_name then
            already_purged = true
            break
        end
    end
    if not already_purged then
        table.insert(self.plugin.settings.purged_devices, device_name)
        self.plugin:saveSettings()
    end

    self:_writeAndPushTombstone(device_name, true, on_complete)
end

function SyncManager:unpurgeDevice(device_name, on_complete)
    local purged_devices = self.plugin.settings.purged_devices or {}
    local index_to_remove = nil
    for i, name in ipairs(purged_devices) do
        if name == device_name then
            index_to_remove = i
            break
        end
    end
    if index_to_remove then
        table.remove(purged_devices, index_to_remove)
        self.plugin:saveSettings()
    end

    self:_writeAndPushTombstone(device_name, false, on_complete)
end

function SyncManager:_writeAndPushTombstone(device_name, removed, on_complete)
    local document, json_path = self:_getCurrentDocumentAndProgressPath()
    if not document then
        if on_complete then on_complete(false) end
        return
    end

    self:saveLocalProgress(document, json_path)
    local progress_map = utils.read_json(json_path) or {}
    progress_map[device_name] = { removed = removed, timestamp = os.date("%Y-%m-%d %H:%M:%S") }
    util.writeToFile(json.encode(progress_map), json_path, true, false, true)

    if not NetworkMgr:isConnected() then
        if on_complete then on_complete(false) end
        return
    end
    remote.push_progress_bg(self.plugin, json_path, function(success)
        if on_complete then on_complete(success) end
    end)
end

-- Sync all changed documents listed in changed_documents.lua
function SyncManager:syncAllChangedDocuments()
    local total, changed_docs = changed_documents.get_pending()
    if total == 0 then
        utils.show_msg("No changed documents to sync.")
        return
    end

    local file_list = {}
    for file, _ in pairs(changed_docs) do
        table.insert(file_list, file)
    end

    local count = 0
    local failed_files = {}
    local ui_document = self.plugin.ui and self.plugin.ui.document

    local function processNext(index)
        if index > #file_list then
            -- All files processed
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
            return
        end

        local file = file_list[index]
        local document = self:getDocumentByFile(file)
        if document then
            logger.info("AnnotationSync: syncing document: " .. file)
            local is_temporary = (document ~= ui_document)

            local callback_called = false
            local function on_sync_complete(success)
                if callback_called then return end
                callback_called = true

                if success then
                    count = count + 1
                else
                    table.insert(failed_files, file)
                end

                if is_temporary then
                    logger.info("AnnotationSync: closing temporary document: " .. file)
                    document:close()
                end

                processNext(index + 1)
            end

            local ok, err = pcall(function()
                self:syncDocument(document, false, on_sync_complete)
            end)

            if not ok then
                logger.warn("AnnotationSync: syncDocument CRASHED for " .. file .. ": " .. tostring(err))
                if not callback_called then
                    on_sync_complete(false)
                end
            end
        else
            -- Check if file still exists
            if not util.fileExists(file) then
                logger.warn("AnnotationSync: file missing, removing from sync list: " .. file)
                changed_documents.remove_by_path(file)
            else
                logger.warn("AnnotationSync: could not open document for sync: " .. file)
                table.insert(failed_files, file)
            end
            processNext(index + 1)
        end
    end

    processNext(1)
end

-- Scans the whole library for books with local annotations that have never
-- been marked for sync, queues them alongside anything already pending, and
-- runs the normal (merge-safe) Sync All over the result. Unlike Sync All,
-- this isn't gated on "has something changed since last sync" -- it exists
-- to seed the cloud from books synced before this plugin was installed
-- (gh-89).
function SyncManager:scanAndSyncAllBooks()
    local home_dir = G_reader_settings:readSetting("home_dir")
    if not home_dir or home_dir == "" then
        utils.show_msg(_("No home directory configured; cannot scan library."))
        return
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Scan your whole library for books with annotations that have never been synced, and sync them?\n\nThis walks your library on disk and may take a while for large collections."),
        ok_text = _("Scan && Sync"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:_scanAndSyncLibrary(home_dir)
        end,
    })
end

function SyncManager:_scanAndSyncLibrary(home_dir)
    local Trapper = require("ui/trapper")
    local excluded_dirs = self.plugin.settings.progress_sync_excluded_dirs or {}

    Trapper:wrap(function()
        local completed, found, scanned, skipped = Trapper:dismissableRunInSubprocess(function()
            return library_scan.find_unsynced_books(home_dir, excluded_dirs)
        end, _("Scanning library… (tap to cancel)"))

        if not completed then
            utils.show_msg(_("Library scan cancelled."))
            return
        end

        found = found or {}
        if #found == 0 then
            utils.show_msg(T(_("Scanned %1 book(s); everything is already synced."), scanned or 0))
            return
        end

        for _, file in ipairs(found) do
            changed_documents.add(file)
        end

        if skipped and skipped > 0 then
            utils.show_msg(T(_("Marked %1 book(s) for sync (skipped %2 unreadable). Syncing now…"), #found, skipped))
        else
            utils.show_msg(T(_("Marked %1 book(s) for sync. Syncing now…"), #found))
        end

        self:syncAllChangedDocuments()
    end)
end

-- Orchestrates the sync process for a single document
function SyncManager:syncDocument(document, is_manual, on_complete)
    local file = document and document.file
    if not file then
        if on_complete then on_complete(false) end
        return false
    end

    utils.flush_settings()
    logger.dbg("AnnotationSync: syncing document: " .. file)

    local json_path = self:writeAnnotationsJSON(document)
    if not json_path then
        if on_complete then on_complete(false) end
        return false
    end

    logger.dbg("AnnotationSync: remote sync of " .. json_path .. " (force=" .. tostring(is_manual) .. ")")
    local sync_success = false
    remote.sync_annotations(self.plugin, document, json_path, function(success, merged_list)
        sync_success = success
        self:_onSyncComplete(document, success, merged_list)
        if on_complete then
            on_complete(success, merged_list)
        end
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
            self:applySyncedAnnotations(document, merged_list)
        end
        changed_documents.remove(document)
    else
        logger.warn("AnnotationSync: sync failed for " .. (document.file or "unknown") .. ", keeping in changed list")
    end
end

function SyncManager:applySyncedAnnotations(document, merged_list)
    if self.plugin.ui and self.plugin.ui.annotation and self.plugin.ui.document == document then
        local unchanged = merged_list.unchanged

        -- 1. Sort for UI consistency
        table.sort(merged_list, function(a, b)
            local cmp = annotations.compare_positions(a.page, b.page, document)
            return (cmp or 0) < 0
        end)
        -- 2. Update active widget state
        self.plugin.ui.annotation.annotations = merged_list
        self.plugin.ui.annotation:onSaveSettings()

        -- 3. Notify system, unless the merge changed nothing: broadcasting
        -- a no-op AnnotationsModified still reaches KOReader's own
        -- ReaderAnnotation:onAnnotationsModified, which stamps a fresh
        -- datetime_updated -- breaking resync idempotency by mutating
        -- state on every sync, changed or not.
        if #merged_list > 0 and not unchanged then
            UIManager:broadcastEvent(Event:new("AnnotationsModified", merged_list))
        end

        -- 4. Trigger Refreshes
        if not document.is_pdf then
            document:render()
            self.plugin.ui.view:recalculate()
            UIManager:setDirty(self.plugin.ui.view.dialog, "partial")
        else
            if document.resetTileCacheValidity then
                document:resetTileCacheValidity()
            end
            if self.plugin.ui.view and self.plugin.ui.view.dialog then
                UIManager:setDirty(self.plugin.ui.view.dialog, "ui")
            end
        end
    else
        -- Update sidecar directly for inactive document
        local annotation_sidecar = docsettings:open(document.file)
        annotation_sidecar:saveSetting("annotations", merged_list)
        annotation_sidecar:flush()
    end
end

function SyncManager:onAnnotationsModified(changed_annotations)
    if not changed_annotations or type(changed_annotations) ~= "table" then
        logger.warn("AnnotationSync: Document annotations modification detected, but could not process provided annotations payload (of type: " .. type(changed_annotations) .. ")")
        return
    end

    -- only want to handle each changed file once, so let's keep track
    local changed_files = {}
    local unknown_file = "unknown_file"

    -- find changed files for payload annotations
    for _, annotation in ipairs(changed_annotations) do
        local changed_file = annotation.book_path
        -- AnnotationsModified event payload does not include book_path for an active document
        if not changed_file then
            changed_file = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
        end
        if not changed_file then
            changed_file = unknown_file
        end
        local count = changed_files[changed_file]
        changed_files[changed_file] = (count and count + 1) or 1
    end

    -- handle changed files
    for changed_file, changes in pairs(changed_files) do
        if changed_file == unknown_file then
            if changes > 0 then
                logger.warn("AnnotationSync: Document annotations modification detected, but could not determine file for " .. changes .. " annotations")
            end
        else
            logger.dbg("AnnotationSync: " .. changes .. " Document annotations modified: " .. changed_file)
            changed_documents.add(changed_file)
        end
    end
end


return SyncManager