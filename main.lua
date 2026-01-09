local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local SyncService = require("apps/cloudstorage/syncservice")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local DataStorage = require("datastorage")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")

local AnnotationSyncPlugin = WidgetContainer:extend {
    name = "AnnotationSync",
    is_doc_only = true,
    _changed_documents = {}, -- Track changed documents
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
        sub_item_table = { {
            text = _("Settings"),
            sub_item_table = { {
                text = _("Cloud settings"),
                callback = function()
                    local sync_service = SyncService:new {}
                    sync_service.onConfirm = function(server)
                        self:onSyncServiceConfirm(server)
                    end
                    UIManager:show(sync_service)
                end
            }, {
                text = _("Use filename instead of hash"),
                checked_func = function()
                    return G_reader_settings:isTrue("annotation_sync_use_filename")
                end,
                callback = function()
                    local current = G_reader_settings:isTrue("annotation_sync_use_filename")
                    G_reader_settings:saveSetting("annotation_sync_use_filename", not current)
                    UIManager:close()
                end
            } }
        }, {
            text = _("Manual Sync"),
            enabled = (G_reader_settings:readSetting("cloud_download_dir") or "") ~= "",
            callback = function()
                self:manualSync()
            end
        } }
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

    local use_filename = G_reader_settings:isTrue("annotation_sync_use_filename")
    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then
        return
    end
    local stored_annotations = self.ui.annotation and self.ui.annotation.annotations or {}
    local annotation_filename
    if use_filename then
        local filename = file:match("([^/]+)$") or file
        annotation_filename = filename .. ".json"
    else
        local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
        annotation_filename = hash .. ".json"
    end
    local json_path = sdr_dir .. "/" .. annotation_filename
    annotations.write_annotations_json(document, stored_annotations, sdr_dir, annotation_filename)
    remote.sync_annotations(self, json_path)
end

function AnnotationSyncPlugin:onAnnotationsModified(payload)
    -- Try to get the document from the UI context
    local document = self.ui and self.ui.document
    if document and document.file then
        local changed_file = document.file
        print("Document changed: " .. changed_file)
        -- Track in a Lua file in the user data directory
        local data_dir = DataStorage:getDataDir()
        local track_path = data_dir .. "/changed_documents.lua"
        -- Load existing table or create new
        local changed_docs = {}
        local ok, loaded = pcall(dofile, track_path)
        if ok and type(loaded) == "table" then
            changed_docs = loaded
        end
        changed_docs[changed_file] = true
        -- Write table to file
        local f = io.open(track_path, "w")
        if f then
            f:write("return ", serialize_table(changed_docs), "\n")
            f:close()
        else
            print("Failed to open track file: " .. track_path)
        end
    else
        print("Document change detected, but no document context available.")
    end
end

-- Helper to serialize a Lua table as code
function serialize_table(tbl)
    local result = "{\n"
    for k, v in pairs(tbl) do
        result = result .. string.format("  [%q] = %s,\n", k, tostring(v))
    end
    result = result .. "}"
    return result
end

return AnnotationSyncPlugin
