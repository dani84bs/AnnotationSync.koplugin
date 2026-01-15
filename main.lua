local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
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

local manual_sync_description = "Sync annotations and bookmarks of the active document."
local sync_all_description = "Sync annotations and bookmarks of all unsynced documents with pending modifications."

local AnnotationSyncPlugin = WidgetContainer:extend {
    -- see also: _meta.lua
    is_doc_only = false,

    settings = nil,
}

AnnotationSyncPlugin.default_settings = {
    last_sync = "Never",
    use_filename= false,
}

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()

    self.settings = G_reader_settings:readSetting(self.plugin_id, self.default_settings)

    -- Migrate old annotation_sync_use_filename setting
    if G_reader_settings:has("annotation_sync_use_filename") then
        self.settings.use_filename = G_reader_settings:isTrue("annotation_sync_use_filename")
        G_reader_settings:delSetting("annotation_sync_use_filename")
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
                    self:syncAllChangedDocuments()
                end,
                separator = true,
            },
            {
                enabled = false,
                text_func = function()
                   return T(_("Last sync: %1"), self.settings.last_sync)
                end
            },
        }
    }

end

function AnnotationSyncPlugin:hasPendingChangedDocuments()
    local count, _ = self:getPendingChangedDocuments()
    return count > 0
end

function AnnotationSyncPlugin:getPendingChangedDocuments()
    local count = 0
    local track_path = self:changedDocumentsFile()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" then
        for _ in pairs(changed_docs) do count = count + 1 end
    end
    return count, changed_docs
end

-- Sync all changed documents listed in changed_documents.lua
function AnnotationSyncPlugin:syncAllChangedDocuments()
    local total, changed_docs = self:getPendingChangedDocuments()
    if total == 0 then
        utils.show_msg("No changed documents to sync.")
        return
    end
    local count = 0
    for file, _ in pairs(changed_docs) do
        -- Try to get a document object for this file, open if needed
        local document = self:getDocumentByFile(file)
        if document then
            self:syncDocument(document)
            count = count + 1
        end
    end
    if count == 0 then
        utils.show_msg("Unable to sync modified documents: " .. total)
    else
        self:updateLastSync("Sync All")
        utils.show_msg("Successfully synced modified documents: " .. count)
    end
end

function AnnotationSyncPlugin:updateLastSync(descriptor)
    local parenthetical = ""
    if descriptor and type(descriptor) == "string" then
        parenthetical = " (" .. descriptor .. ")"
    end
    self.settings.last_sync = os.date("%Y-%m-%d %H:%M:%S") .. parenthetical
    logger.dbg("AnnotationSync: updateLastSync: updated at " .. self.settings.last_sync)
end

-- Helper to sync a document (same as manualSync but for a given document)
function AnnotationSyncPlugin:syncDocument(document)
    local file = document and document.file
    if not file then return end
    logger.dbg("AnnotationSync: syncing document: " .. file)
    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return end

    local stored_annotations = self:getAnnotationsForDocument(document)

    local annotation_filename
    if self.settings.use_filename then
        local filename = file:match("([^/]+)$") or file
        annotation_filename = filename .. ".json"
    else
        local hash = file and type(file) == "string" and util.partialMD5(file) or _("No hash")
        annotation_filename = hash .. ".json"
    end
    local json_path = sdr_dir .. "/" .. annotation_filename
    annotations.write_annotations_json(document, stored_annotations, sdr_dir, annotation_filename)
    logger.dbg("AnnotationSync: remote sync of " .. json_path)
    remote.sync_annotations(self, document, json_path)
    -- Remove from changed_documents.lua if present (very last action)
    self:removeFromChangedDocumentsFile(document)
end

-- Helper to get a document object by file path (stub, needs integration with document management)
function AnnotationSyncPlugin:getDocumentByFile(file)
    -- This is a stub. Replace with actual lookup if available.
    -- If only the current document is available, return it if it matches.
    local document = self.ui and self.ui.document
    if document and document.file == file then
        return document
    end
    document = DocumentRegistry:openDocument(file)
    -- crengine documents must be rendered in order to use their XPointer functions
    if document.provider == "crengine" then
        logger.dbg("AnnotationSync: rendering: " .. file)
        document:render()
    end
    return document
end

function AnnotationSyncPlugin:onAnnotationSyncSyncAll()
    self:syncAllChangedDocuments()
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
    self:updateLastSync("Manual Sync")
    self:syncDocument(document)
end


function AnnotationSyncPlugin:onAnnotationsModified(payload)
    -- Try to get the document from the UI context
    local document = self.ui and self.ui.document
    if document and document.file then
        local changed_file = document.file
        logger.dbg("AnnotationSync: Document annotations modified: " .. changed_file)
        self:addToChangedDocumentsFile(document)
    else
        logger.warn("AnnotationSync: Document annotations modification detected, but no document context available.")
    end
end

-- Get annotations associated with given document
function AnnotationSyncPlugin:getAnnotationsForDocument(document)
    -- Handle active document
    if document == self.ui.document and self.ui.annotation and self.ui.annotation.annotations then
        return self.ui.annotation.annotations
    end
    -- Handle inactive document
    local anotation_reader = ReaderAnnotation:new{ document = document }
    local annotation_sidecar = LuaSettings:open(anotation_reader:getExportAnnotationsFilepath())
    local result = annotation_sidecar:readSetting("annotations")
    return result or {}
end

-- Lua file in the user data directory to track changed documents
function AnnotationSyncPlugin:changedDocumentsFile()
    return DataStorage:getDataDir() .. "/changed_documents.lua"
end

function AnnotationSyncPlugin:addToChangedDocumentsFile(document)
    local file = document and document.file
    local track_path = self:changedDocumentsFile()
    -- Load existing table or create new
    local changed_docs = {}
    local ok, loaded = pcall(dofile, track_path)
    if ok and type(loaded) == "table" then
        changed_docs = loaded
    end
    if file then
        changed_docs[file] = true
        self:writeChangedDocumentsFile(changed_docs)
    end
end

function AnnotationSyncPlugin:removeFromChangedDocumentsFile(document)
    local file = document and document.file
    local track_path = self:changedDocumentsFile()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" and changed_docs[file] then
        changed_docs[file] = nil
        self:writeChangedDocumentsFile(changed_docs)
    end
end

function AnnotationSyncPlugin:writeChangedDocumentsFile(changed_docs)
    local track_path = self:changedDocumentsFile()
    local f = io.open(track_path, "w")
    if f then
        f:write("return ", serialize_table(changed_docs), "\n")
        f:close()
    else
        logger.warn("AnnotationSync: Failed to open changed documents file: " .. track_path)
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
