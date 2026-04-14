local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local annotations = require("annotations")
local utils = require("utils")

local M = {}

function M.sync_annotations(widget, document, json_path, on_complete, force)
    if not widget.ui.cloudstorage then
        UIManager:show(InfoMessage:new {
            text = _("Cloud Storage plugin is not enabled or available."),
            timeout = 4
        })
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = widget.settings.sync_server
    if server then
        widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
            local success, merged_list = annotations.sync_callback(document, local_file, cached_file, income_file, force)
            if on_complete then
                on_complete(success, merged_list)
            end
            return success
        end, not force)
    else
        UIManager:show(InfoMessage:new {
            text = T(_("No cloud destination set in settings.")),
            timeout = 4
        })
        if on_complete then
            on_complete(false)
        end
    end
end

function M.push_progress(widget, json_path, on_complete)
    if not widget.ui.cloudstorage then
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = widget.settings.sync_server
    if server then
        widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
            local local_data = utils.read_json(local_file) or {}
            local income_data = utils.read_json(income_file) or {}

            local_data = M._normalize_progress(local_data)
            income_data = M._normalize_progress(income_data)

            local changed = false
            for device_id, data in pairs(income_data) do
                if not local_data[device_id] or (data.timestamp or "") > (local_data[device_id].timestamp or "") then
                    local_data[device_id] = data
                    changed = true
                end
            end

            if changed then
                local f = io.open(local_file, "w")
                if f then
                    f:write(json.encode(local_data))
                    f:close()
                end
            end

            if on_complete then
                on_complete(true)
            end
            return true
        end, true) -- is_silent = true
    else
        if on_complete then
            on_complete(false)
        end
    end
end

function M.pull_progress(widget, json_path, on_complete)
    if not widget.ui.cloudstorage then
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = widget.settings.sync_server
    if server then
        widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
            local local_data = utils.read_json(local_file) or {}
            local income_data = utils.read_json(income_file) or {}

            local_data = M._normalize_progress(local_data)
            income_data = M._normalize_progress(income_data)

            local changed = false
            for device_id, data in pairs(income_data) do
                if not local_data[device_id] or (data.timestamp or "") > (local_data[device_id].timestamp or "") then
                    local_data[device_id] = data
                    changed = true
                end
            end

            if changed then
                local f = io.open(local_file, "w")
                if f then
                    f:write(json.encode(local_data))
                    f:close()
                end
            end

            if on_complete then
                on_complete(true, local_data)
            end
            return true -- Push merged back to remote
        end, false) -- is_silent = false
    else
        if on_complete then
            on_complete(false)
        end
    end
end

function M._normalize_progress(data)
    if data.device and data.page then
        -- Old format
        local device_id = data.device
        return {
            [device_id] = {
                page = data.page,
                percentage = data.percentage,
                timestamp = data.timestamp,
            }
        }
    end
    return data
end

return M
