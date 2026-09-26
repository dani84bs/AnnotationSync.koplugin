local DataStorage = require("datastorage")
local util = require("util")
local json = require("json")
local logger = require("logger")

local utils = require("utils")
local remote = require("remote")
local keyed_merge = require("keyed_merge")

local M = {}

-- Extractors hand over an array of { merge_key, fields } (their natural
-- extraction-loop shape); keyed_merge.lua and the on-disk JSON both operate
-- on a map keyed by merge_key. These two conversions are the only place that
-- boundary is bridged.
local function records_to_map(records)
    local map = {}
    for _, record in ipairs(records) do
        map[record.merge_key] = { fields = record.fields }
    end
    return map
end

local function map_to_records(map)
    local records = {}
    for merge_key, record in pairs(map) do
        table.insert(records, { merge_key = merge_key, fields = record.fields })
    end
    return records
end

-- Entry point registered on PluginShare.AnnotationSync. Wrapped in pcall so a
-- throwing Extractor (extraction, sync_cb, or writeback_fn) can never abort
-- or corrupt annotation/progress/settings sync running in the same episode.
function M.push(widget, extractor_id, filename, records, writeback_fn)
    local ok, err = pcall(M._push, widget, extractor_id, filename, records, writeback_fn)
    if not ok then
        logger.warn("AnnotationSync: extractor push failed for " ..
            tostring(extractor_id) .. "/" .. tostring(filename) .. ": " .. tostring(err))
    end
end

function M._push(widget, extractor_id, filename, records, writeback_fn)
    -- Local storage nests by extractor_id for on-disk readability, but the
    -- basename itself still carries the extractor_id/filename join: every
    -- KOReader sync transport (Cloud:sync, SyncService.sync) reduces whatever
    -- path it's given to ffiUtil.basename(file_path) before talking to the
    -- remote, so only the basename survives upload -- a bare "spanish.json"
    -- would lose the namespacing remotely regardless of local nesting.
    local dir = DataStorage:getDataDir() .. "/extractors/" .. extractor_id
    util.makePath(dir)
    local json_path = dir .. "/" .. extractor_id .. "__" .. filename .. ".json"

    local ok, write_err = util.writeToFile(json.encode(records_to_map(records)), json_path, true, false, true)
    if not ok then
        logger.warn("AnnotationSync: failed to write extractor JSON: " .. json_path .. " (" .. tostring(write_err) .. ")")
        writeback_fn(records)
        return
    end

    local sync_cb = function(local_file, cached_file, income_file)
        local local_data = utils.read_json(local_file) or {}
        local income_data = utils.read_json(income_file) or {}

        local merged, changed = keyed_merge.merge(local_data, income_data)
        -- Always persist the merged result locally, regardless of `changed`:
        -- `changed` answers "does remote need this," which is a separate
        -- question from "did local's own on-disk cache just learn something
        -- from incoming" -- skipping this write on every non-upload merge
        -- let the local cache drift stale against what writeback_fn already
        -- received.
        util.writeToFile(json.encode(merged), local_file, true, false, true)

        writeback_fn(map_to_records(merged))
        return changed
    end

    local attempted = remote.push_extractor_data(widget, json_path, sync_cb)
    if not attempted then
        -- No provider/destination configured: nothing to merge against.
        writeback_fn(records)
    end
end

return M
