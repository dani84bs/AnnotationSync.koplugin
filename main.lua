local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local SyncService = require("apps/cloudstorage/syncservice")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")

local AnnotationSyncPlugin = WidgetContainer:extend{
    name = "AnnotationSync",
    is_doc_only = true
}

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    utils.insert_after_statistics("annotation_sync_plugin")
    self:onDispatcherRegisterActions()
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = "tools",
        sub_item_table = {{
            text = _("Settings"),
            callback = function()
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    self:onSyncServiceConfirm(server)
                end
                UIManager:show(sync_service)
            end
        }, {
            text = _("Manual Sync"),
            enabled = (G_reader_settings:readSetting("cloud_download_dir") or "") ~= "",
            callback = function()
                self:manualSync()
            end
        }}
    }
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
        text = _("Sync annotations and bookmarks with AnnotationSync."),
        separator = true,
        reader = true
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
        utils.show_msg("A document must be active to sync.")
        return
    end

    local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        return
    end
    local stored_annotations = self.ui.annotation and self.ui.annotation.annotations or {}
    local annotation_filename = hash .. ".json"
    local json_path = sdr_dir .. "/" .. annotation_filename
    annotations.write_annotations_json(document, stored_annotations, sdr_dir)
    remote.sync_annotations(self, json_path)

end

return AnnotationSyncPlugin
