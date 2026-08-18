local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local json = require("json")
local util = require("util")
local gettext = require("gettext")
local _ = gettext
local DataStorage = require("datastorage")
local logger = require("logger")

local remote = require("remote")
local utils = require("utils")
local changed_documents = require("changed_documents")
local settings_sync = require("settings_sync")
local SyncManager = require("manager")
local SettingsSelection = require("settings_selection")
local menus = require("menus")

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local manual_sync_description = "Sync annotations and bookmarks of the active document."
local sync_all_description = "Sync annotations and bookmarks of all unsynced documents with pending modifications."
local sync_all_including_unread_description = "Scan the whole library for books with annotations that have never been synced, and sync them too."
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
    progress_sync_excluded_dirs = {},
    purged_devices = {},
    menu_location = "tools",
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
    self.settings.progress_sync_excluded_dirs = self.settings.progress_sync_excluded_dirs or {}
    self.settings.purged_devices = self.settings.purged_devices or {}
    if self.settings.menu_location == nil then
        self.settings.menu_location = self.default_settings.menu_location
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

    local track_path = changed_documents.path()
    if track_path and util.fileExists(track_path) then
        os.remove(track_path)
    end
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    return menus.build_main_menu(self, menu_items)
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
    if changed_documents.has_pending() then
        utils.show_msg("AnnotationSync: Network available, syncing all changed documents")
        UIManager:scheduleIn(1, function()
            self.manager:syncAllChangedDocuments()
        end)
    end
end

function AnnotationSyncPlugin:onAnnotationSyncSyncAll()
    self.manager:syncAllChangedDocuments()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncSyncAllIncludingUnread()
    self.manager:scanAndSyncAllBooks()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncManualSync()
    self:manualSync()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncPushSettings()
    settings_sync.push(self)
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncPullSettings()
    settings_sync.pull(self)
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
    Dispatcher:registerAction("annotation_sync_sync_all_including_unread", {
        category = "none",
        event = "AnnotationSyncSyncAllIncludingUnread",
        title = _("AnnotationSync: Sync All (including unread)"),
        text = _(sync_all_including_unread_description),
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
    self.manager:applySyncedAnnotations(document, current)

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
    if self.manager then
        self.manager:onAnnotationsModified(annotations)
    end
end

function AnnotationSyncPlugin:showChangedSettings()
    SettingsSelection.show(self)
end

return AnnotationSyncPlugin
