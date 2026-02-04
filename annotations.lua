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
            local zoom = annotation.pos0.zoom or 1
            local page = annotation.page or annotation.pos0.page or 0
            p0 = string.format("%d|%d|%d", page, math.floor(annotation.pos0.x / zoom), math.floor(annotation.pos0.y / zoom))
            p1 = string.format("%d|%d", math.floor(annotation.pos1.x / zoom), math.floor(annotation.pos1.y / zoom))
        else
            p0 = annotation.pos0
            p1 = annotation.pos1
        end
        return p0 .. "||" .. p1
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
    if not a or not b then return 0 end
    if type(a) == "number" and type(b) == "number" then
        return b - a
    end
    if type(a) == "string" and type(b) == "string" then
        return document:compareXPointers(a, b) or 0
    end
    if type(a) == "table" and type(b) == "table" then
        return document:comparePositions(a, b) or 0
    end
    -- Fallback for mixed types (e.g. comparing page number vs XPointer)
    -- We can't do a perfect comparison, but let's at least not crash.
    -- Usually pageno is available in bookmarks and highlights can be mapped to page.
    return 0
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
        local cmp = compare_positions(pos_a, pos_b, document)
        return (cmp or 0) > 0
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

        -- SAFETY (Issue 23): If local is empty but last sync was not, 
        -- it's likely a docsettings failure or fresh device state.
        -- We skip deletion propagation to avoid wiping remote data.
        if #local_keys == 0 and #uploaded_keys > 0 then
            logger.warn("AnnotationSync: Local annotations empty but last sync had " .. #uploaded_keys .. ". Skipping deletions to protect data.")
            return
        end

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

    if not local_map or not last_sync_map or not income_map then
        logger.warn("AnnotationSync: Failed to load one or more sync files. Aborting to prevent data loss.")
        return false
    end

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
            local cmp = compare_positions(local_p, income_p, document)
            if (cmp or 0) > 0 then
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
    local merged_list = M.map_to_list(merged)
    if widget and widget.ui and widget.ui.annotation and widget.ui.document == document then
        table.sort(merged_list, function(a, b)
            local cmp = compare_positions(a.page, b.page, widget.ui.document)
            return (cmp or 0) > 0
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
    else
        -- Update sidecar directly for inactive document or when no UI is present
        local annotation_sidecar = docsettings:open(document.file)
        annotation_sidecar:saveSetting("annotations", merged_list)
        annotation_sidecar:flush()
    end

    local f = io.open(local_file, "w")
    if f then
        f:write(json.encode(merged))
        f:close()
    end
    return true
end

return M
