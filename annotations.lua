local docsettings = require("frontend/docsettings")
local utils = require("utils")
local util = require("util")
local json = require("json")

local M = {}

function M.write_annotations_json(document, stored_annotations, sdr_dir)
    if not document or not sdr_dir then
        return false
    end
    local file = document.file
    local hash = file and type(file) == "string" and util.partialMD5(file) or "no_hash"
    local annotation_map = M.list_to_map(stored_annotations)
    local annotation_filename = (document and document.annotation_file) or (hash .. ".json")
    local json_path = sdr_dir .. "/" .. annotation_filename
    local f = io.open(json_path, "w")
    if f then
        f:write(json.encode(annotation_map))
        f:close()
        return json_path
    end
    return false
end

function M.map_to_list(map)
    local list = {}
    if type(map) == "table" then
        for _, ann in pairs(map) do
            if ann and type(ann.pos0) == "string" and type(ann.pos1) == "string" then
                table.insert(list, ann)
            end
        end
    end
    return list
end

function M.annotation_key(annotation)
    return annotation.pos0 .. "|" .. annotation.pos1
end

function M.list_to_map(annotations)
    local map = {}
    if type(annotations) == "table" then
        for _, ann in ipairs(annotations) do
            local key = M.annotation_key(ann)
            map[key] = ann
        end
    end
    return map
end

function M.flush_metadata(document)
    if document and document.file then
        local ds = docsettings:open(document.file)
        if ds and type(ds.flush) == "function" then
            pcall(function()
                ds:flush()
            end)
        end
    end
end

function M.sync_callback(self, local_file, cached_file, income_file)
    local local_map = utils.read_json(local_file)
    local cached_map = utils.read_json(cached_file)
    local income_map = utils.read_json(income_file)
    -- Merge logic: local wins, then income, then cached
    local merged = {}
    for k, v in pairs(cached_map) do
        merged[k] = v
    end
    for k, v in pairs(income_map) do
        merged[k] = v
    end
    for k, v in pairs(local_map) do
        merged[k] = v
    end

    if self and self.ui and self.ui.annotation then
        local merged_list = M.map_to_list(merged)
        self.ui.annotation.annotations = merged_list
        self.ui.annotation:onSaveSettings()
        self.ui:reloadDocument()
    end

    local f = io.open(local_file, "w")
    if f then
        f:write(json.encode(merged))
        f:close()
    end
    return true
end

return M

