local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")
local util = require("util")

local annotations = require("annotations")
local utils = require("utils")

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local M = {}

local function get_sync_provider(widget)
    if widget.ui.cloudstorage then
        return widget.ui.cloudstorage
    elseif has_syncservice then
        return SyncService
    end
    return nil
end

function M.sync_annotations(widget, document, json_path, on_complete, force)
    local provider = get_sync_provider(widget)
    if not provider then
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
        local sync_cb = function(local_file, cached_file, income_file)
            local success, merged_list = annotations.sync_callback(document, local_file, cached_file, income_file, force)
            if on_complete then
                on_complete(success, merged_list)
            end
            return success
        end

        if widget.ui.cloudstorage then
            widget.ui.cloudstorage:sync(server, json_path, sync_cb, not force)
        else
            SyncService.sync(server, json_path, sync_cb, not force)
        end
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
        util.writeToFile(json.encode(local_data), local_file, true, false, true)
    end

    return true, local_data
end

local function run_silent(widget, func, on_timeout)
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
    UIManager:scheduleIn(15, function()
        if not restored then
            if on_timeout then
                on_timeout()
            end
            restore()
        end
    end)

    func(restore)
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
        local completed = false
        local cb_called = false
        local function on_complete_once(success)
            if not completed then
                completed = true
                if on_complete then
                    on_complete(success)
                end
            end
        end

        run_silent(widget, function(restore)
            local success = widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
                cb_called = true
                local success, local_data = M._sync_progress_callback(local_file, cached_file, income_file)
                on_complete_once(success)
                UIManager:nextTick(restore)
                return success
            end, true) -- is_silent = true

            if success == false then
                on_complete_once(false)
                restore()
            elseif not cb_called and success ~= nil then
                on_complete_once(false)
                restore()
            end
        end, function()
            on_complete_once(false)
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
        local logger = require("logger")
        Trapper:wrap(function()
            local completed, success = Trapper:dismissableRunInSubprocess(function()
                local sync_success = false
                run_silent(widget, function(restore)
                    local res = widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
                        sync_success = M._sync_progress_callback(local_file, cached_file, income_file)
                        UIManager:nextTick(restore)
                        return sync_success
                    end, true)
                    if res == false then
                        restore()
                    end
                end)
                return sync_success
            end, false)
            if completed and not success then
                logger.info("AnnotationSync: background progress sync failed/unsupported, falling back to in-process sync")
                M.push_progress(widget, json_path, on_complete)
            else
                if on_complete then
                    on_complete(completed and success)
                end
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
