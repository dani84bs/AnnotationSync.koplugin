local DocumentRegistry = require("document/documentregistry")
local DataStorage = require("datastorage")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")
local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")

local SyncManager = {}

function SyncManager:new(plugin)
    local o = {
        plugin = plugin
    }
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Sync all changed documents listed in changed_documents.lua
function SyncManager:syncAllChangedDocuments()
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
            self:syncDocument(document, false)
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

-- Orchestrates the sync process for a single document
function SyncManager:syncDocument(document, is_manual)
    local file = document and document.file
    if not file then return end

    self:_flushSettings()
    logger.dbg("AnnotationSync: syncing document: " .. file)

    local sdr_dir = docsettings:getSidecarDir(file)
    if not sdr_dir or sdr_dir == "" then return end

    local filename = self:_getAnnotationFilename(file)
    local json_path = sdr_dir .. "/" .. filename

    annotations.write_annotations_json(document, self:getAnnotationsForDocument(document), sdr_dir, filename)

    logger.dbg("AnnotationSync: remote sync of " .. json_path .. " (force=" .. tostring(is_manual) .. ")")
    remote.sync_annotations(self.plugin, document, json_path, function(success, merged_list)
        self:_onSyncComplete(document, success, merged_list)
    end, is_manual)
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

-- Helper to get a document object by file path
function SyncManager:getDocumentByFile(file)
    -- If only the current document is available, return it if it matches.
    local document = self.plugin.ui and self.plugin.ui.document
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