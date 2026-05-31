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

function M._sync_progress_callback(local_file, cached_file, income_file)
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

    return true, local_data
end

local function run_silent(widget, func)
    local old_show = UIManager.show
    local new_show
    new_show = function(self, widget_item)
        if widget_item.text == _("Successfully synchronized.") then
            return
        end
        return old_show(self, widget_item)
    end
    UIManager.show = new_show

    local restored = false
    local function restore()
        if not restored then
            restored = true
            if UIManager.show == new_show then
                UIManager.show = old_show
            end
        end
    end

    -- Timeout safety fallback (15 seconds)
    UIManager:scheduleIn(15, restore)

    func(function()
        restore()
    end)
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
        run_silent(widget, function(restore)
            local success = widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
                local success, local_data = M._sync_progress_callback(local_file, cached_file, income_file)
                if on_complete then
                    on_complete(success)
                end
                restore()
                return success
            end, true) -- is_silent = true
            if success == false then
                restore()
            end
        end)
    else
        if on_complete then
            on_complete(false)
        end
    end
end

function M.push_progress_bg(widget, json_path, on_complete)
    if not widget.ui.cloudstorage then
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = widget.settings.sync_server
    if server then
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local completed, success = Trapper:dismissableRunInSubprocess(function()
                local sync_success = false
                run_silent(widget, function(restore)
                    local res = widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
                        sync_success = M._sync_progress_callback(local_file, cached_file, income_file)
                        restore()
                        return sync_success
                    end, true)
                    if res == false then
                        restore()
                    end
                end)
                return sync_success
            end, false)
            if on_complete then
                on_complete(completed and success)
            end
        end)
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
            local success, local_data = M._sync_progress_callback(local_file, cached_file, income_file)
            if on_complete then
                on_complete(success, local_data)
            end
            return success -- Push merged back to remote
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
                pos = data.pos, -- Ensure pos is preserved
                timestamp = data.timestamp,
            }
        }
    end
    return data
end

return M
