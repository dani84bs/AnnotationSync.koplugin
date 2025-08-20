local json = require("json")
local utils = require("utils")
local docsettings = require("frontend/docsettings")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template
local SyncService = require("apps/cloudstorage/syncservice")
local util = require("util")

local annotation_helpers = require("annotations")
local flushDocumentMetadata = annotation_helpers.flushDocumentMetadata
local build_annotation_map = annotation_helpers.build_annotation_map
local sync_callback = annotation_helpers.sync_callback

local safe_json_read = utils.safe_json_read

local AnnotationSyncPlugin = WidgetContainer:extend{
    name = "AnnotationSync"
}

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    utils.insert_after_statistics("annotation_sync_plugin")
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

function AnnotationSyncPlugin:onSyncServiceConfirm(server)
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    if server.type then
        G_reader_settings:saveSetting("cloud_provider_type", server.type)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Cloud destination set to:\n%1\nProvider: %2\nPlease restart KOReader for changes to take effect."),
            server.url, server.type or "unknown"),
        timeout = 4
    })
    UIManager:close()
    if self and self.ui and self.ui.menu and self.ui.menu.showMainMenu then
        self.ui.menu:showMainMenu()
    end
end

function AnnotationSyncPlugin:manualSync()
    local document = self.ui and self.ui.document or nil
    local file = document and document.file or _("No file open")
    local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
    flushDocumentMetadata(document)
    local stored_annotations = self.ui.annotation and self.ui.annotation.annotations or {}
    local annotation_map = build_annotation_map(stored_annotations)
    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        return
    end
    local annotation_filename = (document and document.annotation_file) or (hash .. ".json")
    local json_path = sdr_dir .. "/" .. annotation_filename
    local f = io.open(json_path, "w")
    if f then
        f:write(json.encode(annotation_map))
        f:close()
    end
    local server_json = G_reader_settings:readSetting("cloud_server_object")
    if server_json and server_json ~= "" then
        local server = json.decode(server_json)
        SyncService.sync(server, json_path, function(local_file, cached_file, income_file)
            return sync_callback(self, local_file, cached_file, income_file)
        end, false)
    else
        UIManager:show(InfoMessage:new{
            text = T(_("No cloud destination set in settings.")),
            timeout = 4
        })
    end
end

return AnnotationSyncPlugin
