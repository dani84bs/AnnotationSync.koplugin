local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")
local util = require("util")
local logger = require("logger")

local annotations = require("annotations")
local utils = require("utils")
local run_silent = require("silent_ui").run_silent

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local M = {}

-- gh-97: two hangs with zero log output during an episode, no repro found yet.
-- These boundary logs (only visible with debug logging on) let a future
-- recurrence show whether the stall is before sync_cb ever runs (provider/
-- network layer, outside this plugin) or after (this plugin's own merge code).
local function log_wrapped_sync_cb(label, json_path, sync_cb)
    return function(local_file, cached_file, income_file)
        logger.dbg("AnnotationSync: " .. label .. ": sync_cb entered for " .. json_path)
        local success, result = sync_cb(local_file, cached_file, income_file)
        logger.dbg("AnnotationSync: " .. label .. ": sync_cb returning " .. tostring(success) .. " for " .. json_path)
        return success, result
    end
end

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
        logger.dbg("AnnotationSync: perform_sync: calling provider:sync for " .. json_path)
        provider:sync(server, json_path, log_wrapped_sync_cb("perform_sync", json_path, sync_cb), is_silent)
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
            logger.dbg("AnnotationSync: push_progress: calling provider:sync for " .. json_path)
            local success = provider:sync(server, json_path, bound_retries(log_wrapped_sync_cb("push_progress", json_path, function(local_file, cached_file, income_file)
                cb_called = true
                local success, local_data = M._sync_progress_callback(widget, local_file, cached_file, income_file)
                on_complete_once(success)
                UIManager:nextTick(restore)
                return success
            end)), true) -- is_silent = true

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

local BG_POLL_INTERVAL = 0.25 -- seconds between checks on the background push
local BG_TIMEOUT = 60 -- seconds before a stuck background push is killed

-- A forked child inherits every fd of its parent, listening sockets included
-- (e.g. HttpInspector's :8080). While the child lives the port stays bound
-- even after the parent closes its copy, so re-listening on it fails with
-- EADDRINUSE. Point inherited listening sockets at /dev/null: dup2 keeps the
-- fd number taken, so a stale socket object being garbage-collected in the
-- child can't close an fd the child has since reused.
local function release_inherited_listeners()
    local ffi = require("ffi")
    local C = ffi.C
    require("ffi/posix_h")
    pcall(ffi.cdef, "ssize_t readlink(const char *, char *, size_t);")
    local listening = {}
    for _, path in ipairs{ "/proc/net/tcp", "/proc/net/tcp6" } do
        local f = io.open(path, "r")
        if f then
            for line in f:lines() do
                local fields = {}
                for field in line:gmatch("%S+") do fields[#fields + 1] = field end
                if fields[4] == "0A" and fields[10] then -- 0A = TCP_LISTEN
                    listening[fields[10]] = true
                end
            end
            f:close()
        end
    end
    if not next(listening) then return end
    local devnull = C.open("/dev/null", C.O_RDWR)
    if devnull < 0 then return end
    local buf = ffi.new("char[64]")
    for name in require("libs/libkoreader-lfs").dir("/proc/self/fd") do
        local fd = tonumber(name)
        if fd and fd > 2 and fd ~= devnull then
            local len = C.readlink("/proc/self/fd/" .. name, buf, 63)
            local inode = len > 0 and ffi.string(buf, len):match("^socket:%[(%d+)%]$")
            if inode and listening[inode] then
                C.dup2(devnull, fd)
            end
        end
    end
    C.close(devnull)
end

-- Runs task() in a forked child and calls on_done(result) from the UI loop
-- once it exits. result is the string task() returned, or nil if the fork
-- failed, the task raised, or it ran past BG_TIMEOUT.
--
-- Unlike Trapper:dismissableRunInSubprocess this neither blocks the caller
-- nor puts a TrapWidget on top of the reader: the reader keeps handling
-- page turns while the network round trip happens in the child.
function M._run_in_background(task, on_done)
    local ffiutil = require("ffi/util")
    local pid, read_fd = ffiutil.runInSubProcess(function(_, write_fd)
        pcall(release_inherited_listeners)
        local ok, result = pcall(task)
        ffiutil.writeToFD(write_fd, ok and tostring(result) or "", true)
    end, true)
    if not pid then
        on_done(nil)
        return
    end

    local function collect()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(5, collect)
        end
    end

    local polls_left = math.ceil(BG_TIMEOUT / BG_POLL_INTERVAL)
    local function poll()
        local done = ffiutil.isSubProcessDone(pid)
        if done or ffiutil.getNonBlockingReadSize(read_fd) ~= 0 then
            local result = ffiutil.readAllFromFD(read_fd)
            if not done then
                collect()
            end
            on_done(result ~= "" and result or nil)
            return
        end
        polls_left = polls_left - 1
        if polls_left <= 0 then
            logger.warn("AnnotationSync: background sync timed out, killing pid " .. pid)
            ffiutil.terminateSubProcess(pid)
            UIManager:scheduleIn(5, function()
                ffiutil.readAllFromFD(read_fd) -- close our end
                collect()
            end)
            on_done(nil)
            return
        end
        UIManager:scheduleIn(BG_POLL_INTERVAL, poll)
    end
    UIManager:scheduleIn(BG_POLL_INTERVAL, poll)
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
    if not server then
        if on_complete then
            on_complete(false)
        end
        return
    end

    -- The child has no UI loop, so it must use a backend that syncs
    -- synchronously. cloudstorage.koplugin's Cloud:sync defers the whole
    -- round trip to UIManager:nextTick and would silently do nothing there;
    -- core SyncService.sync runs inline and handles webdav/dropbox.
    if not (has_syncservice and (server.type == "webdav" or server.type == "dropbox")) then
        logger.dbg("AnnotationSync: push_progress_bg: no synchronous backend, pushing in-process")
        M.push_progress(widget, json_path, on_complete)
        return
    end

    M._run_in_background(function()
        local sync_success = false
        logger.dbg("AnnotationSync: push_progress_bg: calling SyncService.sync for " .. json_path)
        SyncService.sync(server, json_path, bound_retries(log_wrapped_sync_cb("push_progress_bg", json_path, function(local_file, cached_file, income_file)
            sync_success = M._sync_progress_callback(widget, local_file, cached_file, income_file)
            return sync_success
        end)), true)
        return sync_success and "ok" or "failed"
    end, function(result)
        if result ~= "ok" then
            logger.info("AnnotationSync: background progress sync failed: " .. tostring(result))
        end
        if on_complete then
            on_complete(result == "ok")
        end
    end)
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
        logger.dbg("AnnotationSync: pull_progress: calling provider:sync for " .. json_path)
        provider:sync(server, json_path, bound_retries(log_wrapped_sync_cb("pull_progress", json_path, function(local_file, cached_file, income_file)
            local success, local_data = M._sync_progress_callback(widget, local_file, cached_file, income_file)
            if on_complete then
                on_complete(success, local_data)
            end
            return success -- Push merged back to remote
        end)), false) -- is_silent = false
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

-- Silent transport for extractor_push.lua: unlike perform_sync, never shows
-- an InfoMessage on a missing provider/destination -- pushExtractorData must
-- run without a dialog of its own for that case, so the caller falls back to
-- an unchanged writeback instead. bound_retries' own give-up message is the
-- one exception, surfaced only on a real, otherwise-invisible conflict hang.
-- Returns whether a sync was actually attempted (not whether it changed
-- anything) -- provider:sync's own return conflates "declined to run" with
-- sync_cb's "nothing changed", which extractor_push.lua's writeback fallback
-- needs to tell apart.
function M.push_extractor_data(widget, json_path, sync_cb)
    local provider = get_sync_provider(widget)
    if not provider then
        return false
    end

    local server = copy_sync_server(widget)
    if not server then
        return false
    end

    logger.dbg("AnnotationSync: push_extractor_data: calling provider:sync for " .. json_path)
    provider:sync(server, json_path, bound_retries(log_wrapped_sync_cb("push_extractor_data", json_path, sync_cb)), true) -- is_silent = true
    return true
end

return M

