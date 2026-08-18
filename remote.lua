local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")
local util = require("util")

local annotations = require("annotations")
local utils = require("utils")
local run_silent = require("silent_ui").run_silent

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local M = {}

-- Adapts SyncService's static sync(server, ...) into the same :sync(server, ...)
-- method call shape as widget.ui.cloudstorage, so callers never branch on backend.
local SyncServiceAdapter = {
    sync = function(_, ...) return SyncService.sync(...) end,
}

local function get_sync_provider(widget)
    if widget.ui.cloudstorage then
        return widget.ui.cloudstorage
    elseif widget.has_syncservice then
        return SyncServiceAdapter
    end
    return nil
end

-- Cloud:sync aliases provider.base to whatever table we pass as `server`,
-- and providers like Dropbox mutate that table in place to cache an access
-- token derived from the refresh token (koreader's DropBox.genAccessToken).
-- Handing over our persisted sync_server settings directly would let that
-- mutation permanently overwrite the refresh token with a short-lived one
-- once it expires, every future sync 401s with no way to recover. A copy
-- also means each sync re-derives its own fresh, never-stale access token.
local function copy_sync_server(widget)
    local server = widget.settings.sync_server
    if not server then
        return nil
    end
    local copy = {}
    for k, v in pairs(server) do
        copy[k] = v
    end
    return copy
end

local MAX_SYNC_CONFLICT_RETRIES = 5

-- cloudstorage.koplugin's Cloud:sync retries a WebDAV If-Match conflict
-- (two devices racing a write) forever -- unlike its koreader sibling
-- SyncService.sync, which bounds the same retry to 5 tries. We can't patch
-- koreader core from here, but the sync_cb we hand to provider:sync can
-- itself refuse to keep going: returning false makes provider:sync's own
-- "callback declined" path give up instead of looping indefinitely.
local function bound_retries(sync_cb)
    local attempts = 0
    return function(...)
        attempts = attempts + 1
        if attempts > MAX_SYNC_CONFLICT_RETRIES then
            utils.show_msg(_("Sync conflict, please try again"))
            return false
        end
        return sync_cb(...)
    end
end

local function perform_sync(widget, json_path, sync_cb, is_silent, on_complete)
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

    local server = copy_sync_server(widget)
    if server then
        provider:sync(server, json_path, sync_cb, is_silent)
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

function M.is_async_sync(widget)
    if widget.ui.cloudstorage and not widget.ui.cloudstorage.is_mock then
        return true
    end
    return false
end

function M.sync_annotations(widget, document, json_path, on_complete, force)
    local completed = false
    local function on_complete_once(success, merged_list)
        if not completed then
            completed = true
            if on_complete then
                on_complete(success, merged_list)
            end
        end
    end

    local sync_cb = function(local_file, cached_file, income_file)
        local success, merged_list = annotations.sync_callback(document, local_file, cached_file, income_file, force)
        on_complete_once(success, merged_list)
        return success
    end

    -- Timeout safety fallback for async sync (15 seconds)
    if M.is_async_sync(widget) then
        UIManager:scheduleIn(15, function()
            if not completed then
                local logger = require("logger")
                logger.warn("AnnotationSync: sync timed out for " .. (document.file or "unknown"))
                on_complete_once(false)
            end
        end)
    end

    perform_sync(widget, json_path, sync_cb, not force, on_complete_once)

    -- If it was synchronous and callback was not called, it failed synchronously.
    if not M.is_async_sync(widget) and not completed then
        on_complete_once(false)
    end
end

function M._sync_progress_callback(widget, local_file, cached_file, income_file)
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

    local purged_devices = widget.settings and widget.settings.purged_devices or {}
    for _, device_id in ipairs(purged_devices) do
        local existing = local_data[device_id]
        if not (existing and existing.removed == true) then
            local_data[device_id] = { removed = true, timestamp = os.date("%Y-%m-%d %H:%M:%S") }
            changed = true
        end
    end

    if changed then
        util.writeToFile(json.encode(local_data), local_file, true, false, true)
    end

    return true, local_data
end

function M.push_progress(widget, json_path, on_complete)
    local provider = get_sync_provider(widget)
    if not provider then
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = copy_sync_server(widget)
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

        run_silent(function(restore)
            local success = provider:sync(server, json_path, bound_retries(function(local_file, cached_file, income_file)
                cb_called = true
                local success, local_data = M._sync_progress_callback(widget, local_file, cached_file, income_file)
                on_complete_once(success)
                UIManager:nextTick(restore)
                return success
            end), true) -- is_silent = true

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
    local provider = get_sync_provider(widget)
    if not provider then
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = copy_sync_server(widget)
    if server then
        local Trapper = require("ui/trapper")
        local logger = require("logger")
        Trapper:wrap(function()
            local completed, success = Trapper:dismissableRunInSubprocess(function()
                local sync_success = false
                run_silent(function(restore)
                    local res = provider:sync(server, json_path, bound_retries(function(local_file, cached_file, income_file)
                        sync_success = M._sync_progress_callback(widget, local_file, cached_file, income_file)
                        UIManager:nextTick(restore)
                        return sync_success
                    end), true)
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
    local provider = get_sync_provider(widget)
    if not provider then
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = copy_sync_server(widget)
    if server then
        provider:sync(server, json_path, bound_retries(function(local_file, cached_file, income_file)
            local success, local_data = M._sync_progress_callback(widget, local_file, cached_file, income_file)
            if on_complete then
                on_complete(success, local_data)
            end
            return success -- Push merged back to remote
        end), false) -- is_silent = false
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

function M._sync_settings_callback(widget, local_file, cached_file, income_file)
    local local_data = utils.read_json(local_file) or {}
    local income_data = utils.read_json(income_file) or {}

    -- Merge incoming settings from other devices
    for device_id, data in pairs(income_data) do
        if device_id ~= utils.get_device_name(widget) then
            local_data[device_id] = data
        end
    end

    util.writeToFile(json.encode(local_data), local_file, true, false, true)
    return true, local_data
end

function M.sync_settings(widget, json_path, on_complete)
    local sync_cb = function(local_file, cached_file, income_file)
        local success, local_data = M._sync_settings_callback(widget, local_file, cached_file, income_file)
        if on_complete then
            on_complete(success, local_data)
        end
        return success
    end
    perform_sync(widget, json_path, sync_cb, false, on_complete)
end

return M

