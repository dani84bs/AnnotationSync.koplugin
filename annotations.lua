local docsettings = require("frontend/docsettings")
local utils = require("utils")
local json = require("json")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local logger = require("logger")

local M = {}

function M.flush_metadata(document, stored_annotations)
    UIManager:broadcastEvent(Event:new("FlushSettings"))
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

local function sort_keys_by_position(t, document)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        local ann_a = t[a]
        local ann_b = t[b]
        local pos_a = ann_a.pos0 or ann_a.page
        local pos_b = ann_b.pos0 or ann_b.page
        return compare_positions(pos_a, pos_b, document) > 0
    end)
    return keys
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
        local local_keys = sort_keys_by_position(local_map, document)
        local uploaded_keys = sort_keys_by_position(last_uploaded_map, document)

        for _, uploaded_k in ipairs(uploaded_keys) do
            local uploaded_v = last_uploaded_map[uploaded_k]
            local local_and_uploaded = false
            for _, local_k in ipairs(local_keys) do
                local local_v = local_map[local_k]
                if positions_intersect(uploaded_v, local_v, document) then
                    local_and_uploaded = true
                    break
                end
                if compare_positions(local_v.page, uploaded_v.page, document) < 0 then
                    break
                end
            end
            if not local_and_uploaded then
                uploaded_v.deleted = true
                uploaded_v.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
                local_map[uploaded_k] = uploaded_v
            end
        end
    end
end

local function is_before(a, b)
    local a_time = a.datetime_updated or a.datetime or 0
    local b_time = b.datetime_updated or b.datetime or 0
    return a_time < b_time
end


function M.sync_callback(widget, document, local_file, last_sync_file, income_file)
    logger.dbg("AnnotationSync:sync_callback: local_file: " .. local_file)
    logger.dbg("AnnotationSync:sync_callback: last_sync_file: " .. last_sync_file)
    logger.dbg("AnnotationSync:sync_callback: income_file: " .. income_file)
    local local_map = utils.read_json(local_file)
    local last_sync_map = utils.read_json(last_sync_file)
    local income_map = utils.read_json(income_file)
    -- Mark deleted annotations in local_map
    M.get_deleted_annotations(local_map, last_sync_map, document)
    local merged = {}

    local local_keys = sort_keys_by_position(local_map, document)
    local income_keys = sort_keys_by_position(income_map, document)
    local l = 1
    local i = 1

    logger.dbg("AnnotationSync:sync_callback: comparing income and local")
    while i <= #income_keys and l <= #local_keys do
        local income_k = income_keys[i]
        local local_k = local_keys[l]
        local income_v = income_map[income_k]
        local local_v = local_map[local_k]

        if positions_intersect(income_v, local_v, document) then
            if is_before(income_v, local_v) then
                merged[local_k] = local_v
            else
                merged[income_k] = income_v
            end
            i = i + 1
            l = l + 1
        else
            local local_p = local_v.pos0 or local_v.page
            local income_p = income_v.pos0 or income_v.page
            if compare_positions(local_p, income_p, document) > 0 then
                merged[local_k] = local_v
                l = l + 1
            else
                merged[income_k] = income_v
                i = i + 1
            end
        end
    end

    while l <= #local_keys do
        local local_k = local_keys[l]
        local local_v = local_map[local_k]
        merged[local_k] = local_v
        l = l + 1
    end

    while i <= #income_keys do
        local income_k = income_keys[i]
        local income_v = income_map[income_k]
        merged[income_k] = income_v
        i = i + 1
    end

    logger.dbg("AnnotationSync:sync_callback: handling active")
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
