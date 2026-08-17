local docsettings = require("frontend/docsettings")
local utils = require("utils")
local json = require("json")
local logger = require("logger")
local util = require("util")
local sweep = require("annotation_sweep")

local M = {}

M.is_annotation = sweep.is_annotation
M.is_bookmark = sweep.is_bookmark
M.annotation_key = sweep.annotation_key
M.compare_positions = sweep.compare_positions
M.positions_intersect = sweep.positions_intersect
M.sort_keys_by_position = sweep.sort_keys_by_position
M.is_before = sweep.is_before


-- Main orchestration for merging local and remote annotations
function M.sync_callback(document, local_file, last_sync_file, income_file, force)
    logger.dbg("AnnotationSync:sync_callback: local_file: " .. local_file)
    logger.dbg("AnnotationSync:sync_callback: last_sync_file: " .. last_sync_file)
    logger.dbg("AnnotationSync:sync_callback: income_file: " .. income_file)

    local local_map = utils.read_json(local_file)
    local last_sync_map = utils.read_json(last_sync_file)
    local income_map = utils.read_json(income_file)

    if not local_map or not last_sync_map then
        logger.warn("AnnotationSync: Failed to load local sync files. Aborting to prevent data loss.")
        return false
    end

    if income_map then
        -- Validate it's an annotation map (heuristic: values must be tables)
        -- AND for non-empty maps, at least one entry must have annotation-like keys.
        local is_valid_schema = true
        for k, v in pairs(income_map) do
            if type(v) ~= "table" then
                logger.warn("AnnotationSync: income_map contains non-table value for key " .. tostring(k) .. ". Aborting.")
                is_valid_schema = false
                break
            end
            -- Schema check: values should have at least one of these keys
            if not (v.datetime_updated or v.datetime or v.page or v.text) then
                logger.warn("AnnotationSync: income_map value for key " .. tostring(k) .. " lacks annotation metadata. Aborting.")
                is_valid_schema = false
                break
            end
        end
        if not is_valid_schema then
            income_map = nil
        end
    end

    if not income_map then
        -- If income_file is not a valid JSON table, it might be a 404 error page from WebDAV (first sync)
        -- We only assume empty state if it's NOT valid JSON at all and looks like a 404 error body.
        local is_likely_404 = false
        local content_snippet = ""
        local f = io.open(income_file, "r")
        if f then
            local content = f:read(1024)
            f:close()
            content_snippet = content and content:sub(1, 100):gsub("%s+", " ") or ""
            
            local ok_json, data = pcall(json.decode, content)
            if not ok_json then
                -- Not valid JSON. Check for explicit 404/Not Found markers.
                if content then
                    local lower_content = content:lower()
                    if lower_content:find("404") or 
                       lower_content:find("not found") or 
                       lower_content:find("notfound") or
                       lower_content:find("could not be located") then
                        is_likely_404 = true
                    end
                end
            elseif type(data) == "table" and data.error_summary and data.error_summary:find("path/not_found") then
                -- Dropbox error: path not found (new book)
                is_likely_404 = true
            end
        else
            -- File doesn't exist at all (SyncService handles this, but just in case)
            is_likely_404 = true
        end

        if is_likely_404 then
            logger.info("AnnotationSync: income_file invalid/text, assuming empty remote state (likely 404).")
            income_map = {}
        else
            logger.warn("AnnotationSync: income_file appears corrupted or server error. Aborting. Snippet: " .. content_snippet)
            return false
        end
    end

    -- Snapshot pre-merge state (deep copy: get_deleted_annotations mutates
    -- local_map's entries in place) to tell a real merge outcome apart from
    -- a no-op resync -- both local_map and merged_list are JSON-loaded, so
    -- comparing against the live in-memory annotations instead would false
    -- positive on float round-trip noise in PDF pos0/pos1 coordinates.
    local pre_merge_list = M.map_to_list(util.tableDeepCopy(local_map))

    -- Mark deleted annotations in local_map
    M.get_deleted_annotations(local_map, last_sync_map, document, force)

    logger.dbg("AnnotationSync:sync_callback: comparing income and local")
    local merged = sweep.merge(local_map, income_map, document)

    logger.dbg("AnnotationSync:sync_callback: handling merged list")
    local merged_list = M.map_to_list(merged)
    merged_list.unchanged = sweep.lists_equal(pre_merge_list, merged_list)

    util.writeToFile(json.encode(merged), local_file, true, false, true)
    return true, merged_list
end

-- Prepares the local sidecar data for syncing
function M.write_annotations_json(document, stored_annotations, sdr_dir, annotation_filename)
    if not document or not sdr_dir then
        return false
    end
    local annotation_map = M.list_to_map(stored_annotations)
    local json_path = sdr_dir .. "/" .. annotation_filename
    if util.writeToFile(json.encode(annotation_map), json_path, true, false, true) then
        return json_path
    end
    return false
end

-- Counts entries in a map without needing document-based position sorting.
local function count_keys(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

-- Detects deletions by comparing local state with last known synced state
function M.get_deleted_annotations(local_map, last_uploaded_map, document, force)
    if type(last_uploaded_map) ~= "table" or type(local_map) ~= "table" then
        return
    end

    -- SAFETY (Issue 23): If local is empty but last sync was not,
    -- it's likely a docsettings failure or fresh device state.
    -- We skip deletion propagation to avoid wiping remote data.
    -- We bypass this safety if 'force' is true (manual sync).
    local uploaded_count = count_keys(last_uploaded_map)
    if not force and count_keys(local_map) == 0 and uploaded_count > 0 then
        logger.warn("AnnotationSync: Local annotations empty but last sync had " .. uploaded_count .. ". Skipping deletions to protect data.")
        return
    end

    sweep.find_deleted(local_map, last_uploaded_map, document)
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

return M
