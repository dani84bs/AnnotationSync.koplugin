local docsettings = require("frontend/docsettings")
local utils = require("utils")
local util = require("util")
local json = require("json")

local M = {}

function M.flush_metadata(document, stored_annotations)
    if document and document.file then
        local ds = docsettings:open(document.file)
        if ds and type(ds.flush) == "function" then
            pcall(function()
                ds:flush()
            end)
        end
        if ds and type(ds.close) == "function" then
            pcall(function()
                ds:close()
            end)
        end
    end
end

function M.write_annotations_json(document, stored_annotations, sdr_dir)
    if not document or not sdr_dir then
        return false
    end
    M.flush_metadata(document, stored_annotations)
    local file = document.file
    local hash = file and type(file) == "string" and util.partialMD5(file) or "no_hash"
    local annotation_map = M.list_to_map(stored_annotations)
    local annotation_filename = hash .. ".json"
    local json_path = sdr_dir .. "/" .. annotation_filename
    local f = io.open(json_path, "w")
    if f then
        f:write(json.encode(annotation_map))
        f:close()
        return json_path
    end
    return false
end

function M.is_annotation(candidate)
    return candidate and type(candidate.pos0) == "string" and type(candidate.pos1) == "string"
end

function M.is_bookmark(candidate)
    return candidate and type(candidate.page) == "string" and not M.is_annotation(candidate)
end

function M.annotation_key(annotation)
    if M.is_annotation(annotation) then
        return annotation.pos0 .. "|" .. annotation.pos1
    elseif M.is_bookmark(annotation) then
        return "BOOKMARK|" .. annotation.page
    end
end

function M.list_to_map(annotations)
    local map = {}
    if type(annotations) == "table" then
        for _, ann in ipairs(annotations) do
            local key = M.annotation_key(ann)
            if type(key) == "string" then
                map[key] = ann
            end
        end
    end
    return map
end

function M.map_to_list(map)
    local list = {}
    if type(map) == "table" then
        for _, ann in pairs(map) do
            if ann and not ann.deleted then
                if M.is_annotation(ann) or M.is_bookmark(ann) then
                    table.insert(list, ann)
                end
            end
        end
    end
    return list
end

local function positions_intersect(a, b, document)
    if not a or not b then
        return false
    end

    if M.annotation_key(a) == M.annotation_key(b) then
        return true
    end

    if not a.pos0 or not a.pos1 or not b.pos0 or not b.pos1 then
        return false
    end

    -- A_Start <= B_Start <= A_End
    if document:compareXPointers(a.pos0, b.pos0) >= 0 and document:compareXPointers(b.pos0, a.pos1) >= 0 then
        return true
    end

    -- B_Start <= A_Start <= B_End
    if document:compareXPointers(b.pos0, a.pos0) >= 0 and document:compareXPointers(a.pos0, b.pos1) >= 0 then
        return true
    end

    return false
end

function M.get_deleted_annotations(local_map, cached_map, document)
    if type(cached_map) == "table" and type(local_map) == "table" then
        for cached_k, cached_v in pairs(cached_map) do
            local found = false
            for local_k, local_v in pairs(local_map) do
                if positions_intersect(cached_v, local_v, document) then
                    found = true
                    break
                end
            end
            if not found then
                cached_v.deleted = true
                local_map[cached_k] = cached_v
            end
        end
    end
end

function M.sync_callback(widget, local_file, cached_file, income_file)
    local local_map = utils.read_json(local_file)
    local cached_map = utils.read_json(cached_file)
    local income_map = utils.read_json(income_file)
    local document = widget.ui.document
    -- Mark deleted annotations in local_map
    M.get_deleted_annotations(local_map, cached_map, document)
    -- Merge logic: local wins, then income, then cached
    local merged = {}
    for k, v in pairs(cached_map) do
        merged[k] = v
    end
    -- Helper to resolve intersecting highlights by datetime_updated
    local function resolve_intersections(map, new_ann)
        for key, ann in pairs(map) do
            if positions_intersect(ann, new_ann, document) then
                local ann_time = ann.datetime_updated or ann.datetime or 0
                local new_time = new_ann.datetime_updated or new_ann.datetime or 0
                if ann_time < new_time then
                    map[key] = nil -- Remove older
                else
                    return false -- Do not add new_ann if older
                end
            end
        end
        return true -- Safe to add new_ann
    end
    -- Merge income_map
    for k, v in pairs(income_map) do
        if resolve_intersections(merged, v) then
            merged[k] = v
        end
    end
    -- Merge local_map
    for k, v in pairs(local_map) do
        if resolve_intersections(merged, v) then
            merged[k] = v
        end
    end

    if widget and widget.ui and widget.ui.annotation then
        local merged_list = M.map_to_list(merged)
        table.sort(merged_list, function(a, b)
            return widget.ui.document:compareXPointers(a.page, b.page) > 0
        end)
        widget.ui.annotation.annotations = merged_list
        widget.ui.annotation:onSaveSettings()
        widget.ui.document:render()
    end

    local f = io.open(local_file, "w")
    if f then
        f:write(json.encode(merged))
        f:close()
    end
    return true
end

return M

