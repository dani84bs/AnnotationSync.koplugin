local DataStorage = require("datastorage")
local util = require("util")
local logger = require("logger")
local utils = require("utils")

local M = {}

function M.path()
    return DataStorage:getDataDir() .. "/changed_documents.lua"
end

local function write(changed_docs)
    local track_path = M.path()
    local ok, err = util.writeToFile(utils.serialize_table(changed_docs), track_path, true, true, true)
    if not ok then
        logger.warn("AnnotationSync: Failed to write changed documents file: " .. track_path .. " (" .. tostring(err) .. ")")
    end
end

function M.get_pending()
    local count = 0
    local track_path = M.path()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" then
        for _ in pairs(changed_docs) do count = count + 1 end
    end
    return count, changed_docs
end

function M.has_pending()
    local count, _ = M.get_pending()
    return count > 0
end

function M.add(file)
    local track_path = M.path()
    -- Load existing table or create new
    local changed_docs = {}
    local ok, loaded = pcall(dofile, track_path)
    if ok and type(loaded) == "table" then
        changed_docs = loaded
    end
    if file and type(file) == "string" then
        changed_docs[file] = true
        write(changed_docs)
    end
end

function M.remove_by_path(file)
    if not file then return end
    local track_path = M.path()
    local ok, changed_docs = pcall(dofile, track_path)
    if ok and type(changed_docs) == "table" and changed_docs[file] then
        changed_docs[file] = nil
        write(changed_docs)
    end
end

function M.remove(document)
    local file = document and document.file
    M.remove_by_path(file)
end

return M
