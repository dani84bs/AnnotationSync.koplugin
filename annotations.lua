local docsettings = require("frontend/docsettings")
local utils = require("utils")
local json = require("json")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

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

function M.write_annotations_json(document, stored_annotations, sdr_dir, annotation_filename)
    if not document or not sdr_dir then
        return false
    end
    M.flush_metadata(document, stored_annotations)
    local file = document.file
    local annotation_map = M.list_to_map(stored_annotations)
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
    return candidate and candidate.pos0 and candidate.pos1
end

function M.is_bookmark(candidate)
    return candidate and candidate.page and not M.is_annotation(candidate)
end

function M.annotation_key(annotation)
    if M.is_annotation(annotation) then
        local p0 = ""
        local p1 = ""
        if type(annotation.pos0) == "table" then
            p0 = tostring(annotation.pos0.x / annotation.pos0.zoom)
            p1 = tostring(annotation.pos1.x / annotation.pos1.zoom)
        else
            p0 = annotation.pos0
            p1 = annotation.pos1
        end
        return p0 .. "|" .. p1
    elseif M.is_bookmark(annotation) then
        return "BOOKMARK|" .. tostring(annotation.page)
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

local function compare_positions(a, b, document)
    if type(a) == "number" and type(b) == "number" then
        return b - a
    end
    if type(a) == "string" and type(b) == "string" then
        return document:compareXPointers(a, b)
    end
    if type(a) == "table" and type(b) == "table" then
        return document:comparePositions(a, b)
    end
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
    if compare_positions(a.pos0, b.pos0, document) >= 0 and compare_positions(b.pos0, a.pos1, document) >= 0 then
        return true
    end

    -- B_Start <= A_Start <= B_End
    if compare_positions(b.pos0, a.pos0, document) >= 0 and compare_positions(a.pos0, b.pos1, document) >= 0 then
        return true
    end

    return false
end

function M.get_deleted_annotations(local_map, last_uploaded_map, document)
    if type(last_uploaded_map) == "table" and type(local_map) == "table" then
        for uploaded_k, uploaded_v in pairs(last_uploaded_map) do
            local local_and_uploaded = false
            for _, local_v in pairs(local_map) do
                if positions_intersect(uploaded_v, local_v, document) then
                    local_and_uploaded = true
                    break
                end
            end
            if not local_and_uploaded then
                uploaded_v.deleted = true
                local_map[uploaded_k] = uploaded_v
            end
        end
    end
end

-- Helper to resolve intersecting highlights by datetime_updated
local function resolve_intersections(map, new_ann, document)
    for key, ann in pairs(map) do
        if positions_intersect(ann, new_ann, document) then
            local ann_time = ann.datetime_updated or ann.datetime or 0
            local new_time = new_ann.datetime_updated or new_ann.datetime or 0
            if ann_time < new_time then
                map[key] = nil -- Remove older
            else
                return false   -- Do not add new_ann if older
            end
        end
    end
    return true -- Safe to add new_ann
end

function M.sync_callback(widget, local_file, last_sync_file, income_file)
    local local_map = utils.read_json(local_file)
    local last_sync_map = utils.read_json(last_sync_file)
    local income_map = utils.read_json(income_file)
    local document = widget.ui.document
    -- Mark deleted annotations in local_map
    M.get_deleted_annotations(local_map, last_sync_map, document)
    -- Merge logic: local wins, then income, then cached
    local merged = {}
    for k, v in pairs(last_sync_map) do
        merged[k] = v
    end
    -- Merge income_map
    for k, v in pairs(income_map) do
        if resolve_intersections(merged, v, document) then
            merged[k] = v
        end
    end
    -- Merge local_map
    for k, v in pairs(local_map) do
        if resolve_intersections(merged, v, document) then
            merged[k] = v
        end
    end

    if widget and widget.ui and widget.ui.annotation then
        local merged_list = M.map_to_list(merged)
        table.sort(merged_list, function(a, b)
            return compare_positions(a.page, b.page, widget.ui.document) > 0
        end)
        widget.ui.annotation.annotations = merged_list
        widget.ui.annotation:onSaveSettings()
        if #merged_list > 0 then
            UIManager:broadcastEvent(Event:new("AnnotationsModified", widget.ui.annotation.annotations))
        end
        if not widget.ui.document.is_pdf then
            widget.ui.document:render()
            widget.ui.view:recalculate()
            UIManager:setDirty(widget.ui.view.dialog, "partial")
        end
    end

    local f = io.open(local_file, "w")
    if f then
        f:write(json.encode(merged))
        f:close()
    end
    return true
end

return M
