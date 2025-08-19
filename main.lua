local function getInMemoryAnnotations(document)
    local json = require("json")
    local candidates = {"highlights", "annotations", "notes", "info", "_document"}
    local found = {}
    if document then
        for _, key in ipairs(candidates) do
            local value = document[key]
            if value ~= nil then
                found[key] = value
            end
        end
    end
    return found
end
local function flushDocumentMetadata(document)
    local docsettings = require("frontend/docsettings")
    if document and document.file then
        local ds = docsettings:open(document.file)
        if ds and type(ds.flush) == "function" then
            pcall(function()
                ds:flush()
            end)
        end
    end
end
local function getBookAnnotations(document)
    if document and type(document.getAnnotations) == "function" then
        local ok, result = pcall(function()
            return document:getAnnotations()
        end)
        if ok and type(result) == "table" then
            return result
        end
    end
    return {}
end
local function readCloudJson(dir, hash)
    local json_path = dir .. "/" .. hash .. ".json"
    local lfs = require("libs/libkoreader-lfs")
    local json = require("json")
    if lfs.attributes(json_path, "mode") == "file" then
        local f = io.open(json_path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            local ok, data = pcall(json.decode, content)
            if ok and type(data) == "table" then
                return data
            end
        end
    end
    return {}
end
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local AnnotationSyncPlugin = WidgetContainer:extend{
    name = "AnnotationSync"
}

local filemanager_order = require("ui/elements/filemanager_menu_order")
local reader_order = require("ui/elements/reader_menu_order")

local utils = require("utils")
utils.insert_after_statistics(filemanager_order, "annotation_sync_plugin")
utils.insert_after_statistics(reader_order, "annotation_sync_plugin")

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = "tools",
        sub_item_table = {{
            text = _("Settings"),
            callback = function()
                -- ...existing code...
                local doc_settings_annotations = nil
                if self and self.ui and self.ui.doc_settings and self.ui.doc_settings.data and
                    self.ui.doc_settings.data.annotations then
                    doc_settings_annotations = self.ui.doc_settings.data.annotations
                end
                local doc_settings_annotations_str = require("json").encode(doc_settings_annotations)
                local annotation_annotations = nil
                if self and self.ui and self.ui.annotation and self.ui.annotation.annotations then
                    annotation_annotations = self.ui.annotation.annotations
                end
                local annotation_annotations_str = require("json").encode(annotation_annotations)
                local in_memory = getInMemoryAnnotations(document)
                local in_memory_str = require("json").encode(in_memory)
                local plugin = self
                local SyncService = require("apps/cloudstorage/syncservice")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    -- Save the chosen cloud provider type and directory path to settings
                    G_reader_settings:saveSetting("cloud_download_dir", server.url)
                    if server.type then
                        G_reader_settings:saveSetting("cloud_provider_type", server.type)
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_(
                            "Cloud download directory set to:\n%1\nProvider: %2\nPlease restart KOReader for changes to take effect."),
                            server.url, server.type or "unknown"),
                        timeout = 4
                    })
                    UIManager:close()
                    if plugin and plugin.ui and plugin.ui.menu and plugin.ui.menu.showMainMenu then
                        plugin.ui.menu:showMainMenu()
                    end
                end
                UIManager:show(sync_service)
            end
        }, {
            text = _("Manual Sync"),
            enabled = (G_reader_settings:readSetting("cloud_download_dir") or "") ~= "",
            callback = function()
                local document = self and self.ui and self.ui.document
                local file = document and document.file or _("No file open")
                local hash = file and type(file) == "string" and require("util").partialMD5(file) or _("No hash")
                flushDocumentMetadata(document)
                local msg
                local data = {}
                local book_annotations = getBookAnnotations(document)
                local annotation_type = "nil"
                local annotation_len = 0
                local annotation_dump = "nil"
                local annotations = nil
                local stored_annotations = {}
                if self and self.ui and self.ui.annotation and self.ui.annotation.annotations then
                    annotations = self.ui.annotation.annotations
                    if type(annotations) == "table" then
                        stored_annotations = annotations
                    end
                end
                -- Build annotation map from current annotations
                local annotation_map = utils.build_annotation_map(stored_annotations)
                -- Retrieve cloud annotations
                local docsettings = require("frontend/docsettings")
                local sdr_dir = docsettings:getSidecarDir(file)
                local cloud_data = readCloudJson(sdr_dir, hash)
                local cloud_map = utils.build_annotation_map(cloud_data)
                -- Merge cloud and local annotation maps
                local merged_map = {}
                for k, v in pairs(annotation_map) do
                    merged_map[k] = v
                end
                for k, v in pairs(cloud_map) do
                    merged_map[k] = v
                end
                if sdr_dir and sdr_dir ~= "" then
                    local annotation_filename = (document and document.annotation_file) or (hash .. ".json")
                    local json_path = sdr_dir .. "/" .. annotation_filename
                    local f = io.open(json_path, "w")
                    if f then
                        f:write(require("json").encode(merged_map))
                        f:close()
                    end
                end
            end
        }}
    }
end

return AnnotationSyncPlugin

