local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local json = require("json")
local util = require("util")
local gettext = require("gettext")
local _ = gettext
local DataStorage = require("datastorage")
local logger = require("logger")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")
local SyncManager = require("manager")
local SettingsSelection = require("settings_selection")
local menus = require("menus")

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local manual_sync_description = "Sync annotations and bookmarks of the active document."
local sync_all_description = "Sync annotations and bookmarks of all unsynced documents with pending modifications."
local jump_to_device_progress_description = "Jump to the reading progress of another device."
local push_progress_description = "Push the reading progress of the active document to the cloud."

local AnnotationSyncPlugin = WidgetContainer:extend {
    -- see also: _meta.lua
    is_doc_only = false,

    settings = nil,
    manager = nil,
    has_syncservice = has_syncservice,
}

AnnotationSyncPlugin.default_settings = {
    last_sync = "Never",
    use_filename= false,
    network_auto_sync = false,
    progress_sync = false,
    progress_sync_interval = 1,
    progress_sync_last_word = false,
    device_name = "",
    selected_settings = {},
}

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)

    -- Ensure the plugin is in the ReaderUI event chain
    local found = false
    for _, child in ipairs(self.ui) do
        if child == self then
            found = true
            break
        end
    end
    if not found then
        table.insert(self.ui, self)
    end

    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()

    self.settings = G_reader_settings:readSetting(self.plugin_id, util.tableDeepCopy(self.default_settings))

    -- Fallback/migration for legacy cloud_server_object
    if not self.settings.sync_server then
        local server_json = G_reader_settings:readSetting("cloud_server_object")
        if server_json and server_json ~= "" then
            local ok, server = pcall(json.decode, server_json)
            if ok and server then
                self.settings.sync_server = server
                self:saveSettings()
            end
        end
    end

    -- Sanitize corrupted settings
    if type(self.settings.progress_sync_interval) ~= "number" then
        self.settings.progress_sync_interval = self.default_settings.progress_sync_interval
    end

    self.manager = SyncManager:new(self)

    -- Migrate old annotation_sync_use_filename setting
    if G_reader_settings:has("annotation_sync_use_filename") then
        self.settings.use_filename = G_reader_settings:isTrue("annotation_sync_use_filename")
        G_reader_settings:delSetting("annotation_sync_use_filename")
    end

    self.settings_key = self.plugin_id

    -- Load plugin translations dynamically if available for the active locale
    local lang = gettext.current_lang
    if lang and lang ~= "C" and lang ~= "" then
        local path = self.path or "plugins/AnnotationSync.koplugin"
        local mo_path = string.format("%s/l10n/%s/annotation_sync.mo", path, lang)
        local f = io.open(mo_path, "r")
        if f then
            f:close()
            gettext.loadMO(mo_path)
        end
    end

    self:registerEvents()
end

function AnnotationSyncPlugin:saveSettings()
    G_reader_settings:saveSetting(self.plugin_id, self.settings)
end

function AnnotationSyncPlugin:deletePluginSettings()
    G_reader_settings:delSetting(self.plugin_id)
    G_reader_settings:delSetting("cloud_server_object")
    G_reader_settings:delSetting("cloud_download_dir")
    G_reader_settings:delSetting("cloud_provider_type")

    local track_path
    if self.manager then
        track_path = self.manager:changedDocumentsFile()
    else
        track_path = DataStorage:getDataDir() .. "/changed_documents.lua"
    end
    if track_path and util.fileExists(track_path) then
        os.remove(track_path)
    end
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Cloud settings"),
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil or self.has_syncservice
                        end,
                        callback = function()
                            if self.ui.cloudstorage then
                                self.ui.cloudstorage:onShowCloudStorageList(function(server)
                                    self:onSyncServiceConfirm(server)
                                end)
                            elseif self.has_syncservice then
                                local sync_service = SyncService:new {}
                                sync_service.onConfirm = function(server)
                                    self:onSyncServiceConfirm(server)
                                end
                                UIManager:show(sync_service)
                            end
                        end
                    },
                    {
                        text = _("Use filename instead of hash"),
                        checked_func = function()
                            return self.settings.use_filename
                        end,
                        callback = function()
                            self.settings.use_filename = not self.settings.use_filename
                            self:saveSettings()
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Automatically Sync All when network becomes available"),
                        checked_func = function()
                            return self.settings.network_auto_sync
                        end,
                        callback = function()
                            self.settings.network_auto_sync = not self.settings.network_auto_sync
                            self:saveSettings()
                            if self.settings.network_auto_sync then
                                self:registerEvents()
                            end
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Enable Reading Progress Sync"),
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil
                        end,
                        checked_func = function()
                            return self.settings.progress_sync
                        end,
                        callback = function()
                            self.settings.progress_sync = not self.settings.progress_sync
                            self:saveSettings()
                            UIManager:close()
                        end,
                    },
                    {
                        text = _("Sync using last word of page"),
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil and self.settings.progress_sync
                        end,
                        checked_func = function()
                            return self.settings.progress_sync_last_word
                        end,
                        callback = function()
                            self.settings.progress_sync_last_word = not self.settings.progress_sync_last_word
                            self:saveSettings()
                            UIManager:close()
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Sync every %1 pages"), self.settings.progress_sync_interval)
                        end,
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil and self.settings.progress_sync
                        end,
                        callback = function()
                            local input
                            input = InputDialog:new{
                                title = _("Sync every # pages"),
                                input = tostring(self.settings.progress_sync_interval),
                                input_type = "number",
                                save_callback = function(val)
                                    local n = tonumber(val)
                                    if n and n > 0 then
                                        self.settings.progress_sync_interval = math.floor(n)
                                        self:saveSettings()
                                        if self.ui.menu and self.ui.menu.showMainMenu then
                                            self.ui.menu:showMainMenu()
                                        end
                                        return true
                                    end
                                end
                            }
                            UIManager:show(input)
                        end,
                    },
                    {
                        text_func = function()
                            local dev_name = self.settings.device_name
                            if not dev_name or dev_name == "" then
                                dev_name = require("device").model or "unknown"
                            end
                            return T(_("Device name: %1"), dev_name)
                        end,
                        enabled_func = function()
                            return true
                        end,
                        callback = function()
                            local default_dev_name = require("device").model or "unknown"
                            local current_val = self.settings.device_name
                            if not current_val or current_val == "" then
                                current_val = default_dev_name
                            end
                            local input
                            input = InputDialog:new{
                                title = _("Set device name"),
                                description = _("Leave empty to use the default device name."),
                                input = current_val,
                                save_callback = function(val)
                                    local dev_name = val:gsub("^%s*(.-)%s*$", "%1")
                                    if dev_name == default_dev_name then
                                        dev_name = ""
                                    end
                                    self.settings.device_name = dev_name
                                    self:saveSettings()
                                    if self.ui.menu and self.ui.menu.showMainMenu then
                                        self.ui.menu:showMainMenu()
                                    end
                                    return true
                                end
                            }
                            UIManager:show(input)
                        end,
                    },
                    {
                        text = _("Show changed settings"),
                        callback = function()
                            self:showChangedSettings()
                        end,
                    },
                    {
                        enabled = false,
                        text_func = function()
                            local server = self.settings.sync_server
                            local cloud_desc = (server and server.url) or _("None")
                            return T(_("Current cloud: %1"), cloud_desc)
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Push settings to cloud"),
                enabled = (self.settings.sync_server ~= nil),
                callback = function()
                    self.manager:pushSettings()
                end
            },
            {
                text = _("Pull settings from cloud"),
                enabled = (self.settings.sync_server ~= nil),
                callback = function()
                    self.manager:pullSettings()
                end
            },
            {
                text = _("Manual Sync"),
                enabled = (self.settings.sync_server ~= nil) and ((self.ui and self.ui.document) ~= nil),
                hold_callback = function()
                    utils.show_msg(manual_sync_description)
                end,
                callback = function()
                    self:manualSync()
                end
            },
            {
                text = _("Push reading progress"),
                enabled_func = function()
                    return (self.ui.cloudstorage ~= nil or self.has_syncservice)
                        and (self.settings.sync_server ~= nil)
                        and ((self.ui and self.ui.document) ~= nil)
                end,
                callback = function()
                    self:onAnnotationSyncPushProgress()
                end
            },
            {
                text = _("Jump to device progress"),
                enabled_func = function()
                    return (self.ui.cloudstorage ~= nil or self.has_syncservice)
                        and (self.settings.sync_server ~= nil)
                        and ((self.ui and self.ui.document) ~= nil)
                end,
                callback = function()
                    self.manager:pullProgress()
                end
            },
            {
                text = _("Sync All"),
                enabled = true,
                hold_callback = function()
                    utils.show_msg(sync_all_description)
                end,
                callback = function()
                    self.manager:syncAllChangedDocuments()
                end,
                separator = true,
            },
            {
                text = _("Show pending/unsynced documents"),
                enabled = true,
                callback = function()
                    menus.show_pending_documents(self)
                end,
            },
            {
                text = _("Show Deleted"),
                enabled = ((self.ui and self.ui.document) ~= nil),
                callback = function()
                    self:showDeletedAnnotations()
                end,
                separator = true,
            },
            {
                enabled = false,
                text_func = function()
                   return T(_("Last sync: %1"), self.settings.last_sync)
                end
            },
            {
                text = T(_("Plugin version: %1"), self.version),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1 (%4)\nVersion: %2\n\n%3"), self.fullname, self.version, self.description, self.plugin_id),
                    })
                end,
            },
        }
    }

    if self.ui.cloudstorage == nil and not self.has_syncservice then
        table.insert(menu_items.annotation_sync_plugin.sub_item_table, {
            text = _("Why are some options greyed out?"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Reading progress sync features are disabled because your KOReader version does not support the cloudstorage plugin.\n\nThese features require a newer KOReader release (not yet available in stable releases)."),
                })
            end,
        })
    end
end

function AnnotationSyncPlugin:registerEvents()
    if self.settings.network_auto_sync then
        self.onNetworkConnected = self._onNetworkConnected
    else
        self.onNetworkConnected = nil
    end
end

function AnnotationSyncPlugin:_onNetworkConnected()
    logger.dbg("AnnotationSync: handling event: NetworkConnected")
    if self.manager:hasPendingChangedDocuments() then
        utils.show_msg("AnnotationSync: Network available, syncing all changed documents")
        UIManager:scheduleIn(1, function()
            self.manager:syncAllChangedDocuments()
        end)
    end
end

function AnnotationSyncPlugin:applySyncedAnnotations(document, merged_list)
    if self.ui and self.ui.annotation and self.ui.document == document then
        -- 1. Sort for UI consistency
        table.sort(merged_list, function(a, b)
            local cmp = annotations.compare_positions(a.page, b.page, document)
            return (cmp or 0) < 0
        end)
        -- 2. Update active widget state
        self.ui.annotation.annotations = merged_list
        self.ui.annotation:onSaveSettings()

        -- 3. Notify system
        if #merged_list > 0 then
            UIManager:broadcastEvent(Event:new("AnnotationsModified", merged_list))
        end

        -- 4. Trigger Refreshes
        if not document.is_pdf then
            document:render()
            self.ui.view:recalculate()
            UIManager:setDirty(self.ui.view.dialog, "partial")
        end
    else
        -- Update sidecar directly for inactive document
        local annotation_sidecar = docsettings:open(document.file)
        annotation_sidecar:saveSetting("annotations", merged_list)
        annotation_sidecar:flush()
    end
end

function AnnotationSyncPlugin:onAnnotationSyncSyncAll()
    self.manager:syncAllChangedDocuments()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncManualSync()
    self:manualSync()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncPushSettings()
    self.manager:pushSettings()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncPullSettings()
    self.manager:pullSettings()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncJumpToDeviceProgress()
    if not self.ui.cloudstorage and not self.has_syncservice then
        utils.show_msg(_("Reading progress sync is not supported on this version of KOReader."))
        return true
    end
    local document = self.ui and self.ui.document
    if not document or not document.file then
        utils.show_msg(_("A document must be active to jump to device progress."))
        return true
    end
    self.manager:pullProgress()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncPushProgress()
    if not self.ui.cloudstorage and not self.has_syncservice then
        utils.show_msg(_("Reading progress sync is not supported on this version of KOReader."))
        return true
    end
    local document = self.ui and self.ui.document
    if not document or not document.file then
        utils.show_msg(_("A document must be active to push reading progress."))
        return true
    end
    utils.show_msg(_("Pushing reading progress..."))
    self.manager:syncProgress(function(success)
        if success then
            utils.show_msg(_("Reading progress pushed successfully."))
        else
            utils.show_msg(_("Failed to push reading progress."))
        end
    end)
    return true
end

function AnnotationSyncPlugin:onPageUpdate(page_pos)
    if self.manager then
        self.manager:onPageUpdate(page_pos)
    end
end

function AnnotationSyncPlugin:onPosUpdate(page_pos)
    if self.manager then
        self.manager:onPageUpdate(page_pos)
    end
end

function AnnotationSyncPlugin:onPagePositionUpdated(page_pos)
    if self.manager then
        self.manager:onPageUpdate(page_pos)
    end
end

function AnnotationSyncPlugin:onCloseDocument()
    if self.manager then
        self.manager:onCloseDocument()
    end
end

function AnnotationSyncPlugin:onSuspend()
    if self.manager then
        self.manager:onSuspend()
    end
end

function AnnotationSyncPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("annotation_sync_manual_sync", {
        category = "none",
        event = "AnnotationSyncManualSync",
        title = _("AnnotationSync: Manual Sync"),
        text = _(manual_sync_description),
        separator = true,
        reader = true
    })
    Dispatcher:registerAction("annotation_sync_push_settings", {
        category = "none",
        event = "AnnotationSyncPushSettings",
        title = _("AnnotationSync: Push settings to cloud"),
        text = _("Push the selected settings to the cloud."),
        separator = true,
        general = true
    })
    Dispatcher:registerAction("annotation_sync_pull_settings", {
        category = "none",
        event = "AnnotationSyncPullSettings",
        title = _("AnnotationSync: Pull settings from cloud"),
        text = _("Pull the selected settings from the cloud."),
        separator = true,
        general = true
    })
    Dispatcher:registerAction("annotation_sync_push_progress", {
        category = "none",
        event = "AnnotationSyncPushProgress",
        title = _("AnnotationSync: Push reading progress"),
        text = _(push_progress_description),
        separator = true,
        reader = true
    })
    Dispatcher:registerAction("annotation_sync_jump_to_device_progress", {
        category = "none",
        event = "AnnotationSyncJumpToDeviceProgress",
        title = _("AnnotationSync: Jump to device progress"),
        text = _(jump_to_device_progress_description),
        separator = true,
        reader = true
    })
    Dispatcher:registerAction("annotation_sync_sync_all", {
        category = "none",
        event = "AnnotationSyncSyncAll",
        title = _("AnnotationSync: Sync All"),
        text = _(sync_all_description),
        separator = true,
        general = true
    })
end

function AnnotationSyncPlugin:onSyncServiceConfirm(server)
    self.settings.sync_server = server
    self:saveSettings()

    -- Keep G_reader_settings updated for legacy compatibility and menu enablement
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    if server.type then
        G_reader_settings:saveSetting("cloud_provider_type", server.type)
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Cloud destination set to:\n%1\nProvider: %2"),
            server.url, server.type or "unknown"),
        timeout = 4
    })
    if self and self.ui and self.ui.menu and self.ui.menu.showMainMenu then
        self.ui.menu:showMainMenu()
    end
end

function AnnotationSyncPlugin:manualSync()
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then
        utils.show_msg("A document must be active to do a manual sync.")
        return
    end
    self.manager:syncDocument(document, true)
    self.manager:updateLastSync("Manual Sync")
end

function AnnotationSyncPlugin:showDeletedAnnotations()
    local document = self.ui and self.ui.document
    if not document then return end
    menus.show_deleted_annotations(self, document)
end

function AnnotationSyncPlugin:restoreAnnotations(anns, silent)
    local document = self.ui and self.ui.document
    if not document or not anns or #anns == 0 then return end

    local now = os.date("%Y-%m-%d %H:%M:%S")
    local current = self.manager:getAnnotationsForDocument(document)

    for _, ann in ipairs(anns) do
        -- 1. Mark as not deleted and update timestamp
        ann.deleted = false
        ann.datetime_updated = now

        -- 2. Add back to current list
        table.insert(current, ann)
    end

    -- 3. Apply changes once (saves to sidecar and refreshes UI)
    self:applySyncedAnnotations(document, current)

    -- 4. Flush to local sync JSON immediately (Fix for Issue #39 delayed flush)
    self.manager:writeAnnotationsJSON(document)

    if not silent then
        if #anns == 1 then
            utils.show_msg(_("Annotation restored."))
        else
            utils.show_msg(T(_("Restored %1 annotations."), #anns))
        end
    end
end

function AnnotationSyncPlugin:restoreAnnotation(ann, silent)
    self:restoreAnnotations({ann}, silent)
end

function AnnotationSyncPlugin:onAnnotationsModified(annotations)
    if not annotations or type(annotations) ~= "table" then
        logger.warn("AnnotationSync: Document annotations modification detected, but could not process provided annotations payload (of type: " .. type(annotations) .. ")")
        return
    end

    -- only want to handle each changed file once, so let's keep track
    local changed_files = {}
    local unknown_file = "unknown_file"

    -- find changed files for payload annotations
    for _, annotation in ipairs(annotations) do
        local changed_file = annotation.book_path
        -- AnnotationsModified event payload does not include book_path for an active document
        if not changed_file then
            changed_file = self.ui and self.ui.document and self.ui.document.file
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
            self.manager:addToChangedDocumentsFile(changed_file)
        end
    end
end

function AnnotationSyncPlugin:showChangedSettings()
    SettingsSelection.show(self)
end

return AnnotationSyncPlugin
