local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local ReaderAnnotation = require("apps/reader/modules/readerannotation")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local SyncService = require("apps/cloudstorage/syncservice")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local DataStorage = require("datastorage")
local logger = require("logger")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")
local SyncManager = require("manager")

local manual_sync_description = "Sync annotations and bookmarks of the active document."
local sync_all_description = "Sync annotations and bookmarks of all unsynced documents with pending modifications."

local AnnotationSyncPlugin = WidgetContainer:extend {
    -- see also: _meta.lua
    is_doc_only = false,

    settings = nil,
    manager = nil,
}

AnnotationSyncPlugin.default_settings = {
    last_sync = "Never",
    use_filename= false,
    network_auto_sync = false,
}

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()

    self.settings = G_reader_settings:readSetting(self.plugin_id, self.default_settings)
    self.manager = SyncManager:new(self)

    -- Migrate old annotation_sync_use_filename setting
    if G_reader_settings:has("annotation_sync_use_filename") then
        self.settings.use_filename = G_reader_settings:isTrue("annotation_sync_use_filename")
        G_reader_settings:delSetting("annotation_sync_use_filename")
    end

    self:registerEvents()
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
                        callback = function()
                            local sync_service = SyncService:new {}
                            sync_service.onConfirm = function(server)
                                self:onSyncServiceConfirm(server)
                            end
                            UIManager:show(sync_service)
                        end
                    },
                    {
                        text = _("Use filename instead of hash"),
                        checked_func = function()
                            return self.settings.use_filename
                        end,
                        callback = function()
                            local current = self.settings.use_filename
                            self.settings.use_filename = not current
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Automatically Sync All when network becomes available"),
                        checked_func = function()
                            return self.settings.network_auto_sync
                        end,
                        callback = function()
                            local current = self.settings.network_auto_sync
                            self.settings.network_auto_sync = not current
                            if self.settings.network_auto_sync then
                                self:registerEvents()
                            end
                            UIManager:close()
                        end
                    },
                },
                separator = true,
            },
            {
                text = _("Manual Sync"),
                enabled = ((G_reader_settings:readSetting("cloud_download_dir") or "") ~= "") and ((self.ui and self.ui.document) ~= nil),
                hold_callback = function()
                    utils.show_msg(manual_sync_description)
                end,
                callback = function()
                    self:manualSync()
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
            return (cmp or 0) > 0
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

function AnnotationSyncPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("annotation_sync_manual_sync", {
        category = "none",
        event = "AnnotationSyncManualSync",
        title = _("AnnotationSync: Manual Sync"),
        text = _(manual_sync_description),
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
    remote.save_server_settings(server)
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

    local deleted = self.manager:getDeletedAnnotations(document)
    if #deleted == 0 then
        utils.show_msg(_("No deleted annotations found for this document."))
        return
    end

    local Menu = require("ui/widget/menu")
    local deleted_menu
    local menu_items = {}

    for i, ann in ipairs(deleted) do
        local text = ann.text or ann.notes or _("Highlight")
        if text == "" then text = _("Highlight") end
        -- Truncate long text
        if #text > 50 then text = text:sub(1, 47) .. "..." end
        
        table.insert(menu_items, {
            text = text,
            callback = function()
                -- For now just show info, we can add restore later if needed
                UIManager:show(InfoMessage:new{
                    text = T(_("Deleted Annotation:\nPage: %1\nText: %2\nDeleted at: %3"), 
                        ann.page, ann.text or ann.notes or "", ann.datetime_updated or "unknown"),
                })
            end
        })
    end

    deleted_menu = Menu:new{
        title = _("Deleted Annotations"),
        item_table = menu_items,
    }
    UIManager:show(deleted_menu)
end

function AnnotationSyncPlugin:onAnnotationsModified(annotations)
    if not annotations and type(annotations) == "table" then
        logger.warn("AnnotationSync: Document annotations modification detected, but could not process provided annotations payload (of type: " .. type(annotations) .. ")")
        return
    end
    for _, annotation in ipairs(annotations) do
        local changed_file = annotation.book_path
        -- AnnotationsModified event payload does not include book_path for an active document
        if not changed_file then
            changed_file = self.ui and self.ui.document and self.ui.document.file
        end
        if not changed_file then
            logger.warn("AnnotationSync: Document annotations modification detected, but could not determine changed file")
            break
        end
        logger.dbg("AnnotationSync: Document annotations modified: " .. changed_file)
        self.manager:addToChangedDocumentsFile(changed_file)
    end
end

return AnnotationSyncPlugin
