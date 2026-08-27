local DataStorage = require("datastorage")
local util = require("util")
local json = require("json")
local logger = require("logger")

local utils = require("utils")
local remote = require("remote")
local keyed_merge = require("keyed_merge")

local M = {}

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
    -- Namespaced by <extractor_id>/<filename> so two Extractors (or one
    -- Extractor's multiple files) can never collide in storage or merge keys.
    local dir = DataStorage:getDataDir() .. "/extractors/" .. extractor_id
    util.makePath(dir)
    local json_path = dir .. "/" .. filename .. ".json"

    local ok, write_err = util.writeToFile(json.encode(records), json_path, true, false, true)
    if not ok then
        logger.warn("AnnotationSync: failed to write extractor JSON: " .. json_path .. " (" .. tostring(write_err) .. ")")
        writeback_fn(records)
        return
    end

    local sync_cb = function(local_file, cached_file, income_file)
        local local_data = utils.read_json(local_file) or {}
        local income_data = utils.read_json(income_file) or {}

        local merged, changed = keyed_merge.merge(local_data, income_data)
        if changed then
            util.writeToFile(json.encode(merged), local_file, true, false, true)
        end

        writeback_fn(merged)
        return changed
    end

    local attempted = remote.push_extractor_data(widget, json_path, sync_cb)
    if not attempted then
        -- No provider/destination configured: nothing to merge against.
        writeback_fn(records)
    end
end

return M
