-- E2E: purge/un-purge a device from progress sync, over a real local
-- WebDAV server.
--
-- Proves gh-90's tombstone write-and-push actually survives a real
-- network round trip: the merge in remote.lua is already covered at the
-- unit seam (spec/unit/progress_purge_merge_spec.lua) and the menu/UI
-- wiring at the integration seam (spec/unit/progress_purge_ui_spec.lua);
-- this is the one layer neither exercises -- a real `push_progress_bg`
-- subprocess actually landing the tombstone on the server, and a real
-- pull actually merging it back in.
describe("AnnotationSync E2E purge device from progress sync", function()
    local Event, UIManager
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, WebDavApi, json

    local function progress_remote_path(sync_instance, file)
        local server = e2e_test_utils.server_config()
        local filename = sync_instance.manager:_getProgressFilename(file)
        local remote_path = WebDavApi:getJoinedPath(server.address, server.url)
        return WebDavApi:getJoinedPath(remote_path, filename)
    end

    local function seed_remote_progress(sync_instance, file, data, test_data_dir)
        local server = e2e_test_utils.server_config()
        local tmp_path = test_data_dir .. "/.seed_remote_progress.json"
        local f = io.open(tmp_path, "w")
        f:write(json.encode(data))
        f:close()
        local code = WebDavApi:uploadFile(progress_remote_path(sync_instance, file), server.username, server.password, tmp_path)
        os.remove(tmp_path)
        return code
    end

    local function fetch_remote_progress(sync_instance, file, test_data_dir)
        local server = e2e_test_utils.server_config()
        local tmp_path = test_data_dir .. "/.fetch_remote_progress.json"
        local code = WebDavApi:downloadFile(progress_remote_path(sync_instance, file), server.username, server.password, tmp_path)
        if not code or code < 200 or code >= 300 then
            os.remove(tmp_path)
            return nil, code
        end
        local f = io.open(tmp_path, "r")
        local content = f:read("*a")
        f:close()
        os.remove(tmp_path)
        local ok, decoded = pcall(json.decode, content)
        if not ok then return nil, code end
        return decoded, code
    end

    local function wait_for(predicate, timeout_seconds)
        local deadline = os.time() + timeout_seconds
        local result
        repeat
            result = predicate()
            if not result then
                require("ffi/util").sleep(0.5)
                fastforward_ui_events()
            end
        until result or os.time() > deadline
        return result
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        UIManager = require("ui/uimanager")
        json = require("json")
        WebDavApi = require("apps/cloudstorage/webdavapi")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("purges a seeded device's real remote progress, then un-purges it", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_purge_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local file = test_data_dir .. "/test.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", file)

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(file, AnnotationSyncPlugin)
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.use_filename = true
        sync_instance.settings.device_name = "PurgeE2E-CurrentDevice"

        -- Simulate a prior sync from a now-retired device, without
        -- actually running a second device.
        local seed_code = seed_remote_progress(sync_instance, file, {
            GhostDevice = { page = 5, percentage = 0.1, timestamp = "2026-01-01 00:00:00" },
        }, test_data_dir)
        assert.is_true(seed_code ~= nil and seed_code >= 200 and seed_code < 300, "could not seed remote progress")

        -- Real sync merges GhostDevice into this device's local progress
        -- map -- required before the purge picker can see it.
        local sync_result
        sync_instance.manager:syncProgress(function(success) sync_result = success end)
        assert.is_true(wait_for(function() return sync_result ~= nil end, 10), "initial sync did not complete")
        assert.is_true(sync_result, "initial sync failed")

        -- Purge, over the real network, and wait for the tombstone to
        -- actually land on the WebDAV server.
        local purge_result
        sync_instance.manager:purgeDevice("GhostDevice", function(success) purge_result = success end)
        assert.is_true(wait_for(function() return purge_result ~= nil end, 10), "purge push did not complete")
        assert.is_true(purge_result, "purge push failed")

        local after_purge, code = fetch_remote_progress(sync_instance, file, test_data_dir)
        assert.is_not_nil(after_purge, "could not fetch remote progress after purge, code=" .. tostring(code))
        assert.is_true(after_purge.GhostDevice.removed, "remote GhostDevice record is not marked removed")
        assert.is_nil(after_purge.GhostDevice.page, "purge should drop the stale page field")

        -- Un-purge, over the real network, and wait for the newer
        -- removed=false record to land.
        local unpurge_result
        sync_instance.manager:unpurgeDevice("GhostDevice", function(success) unpurge_result = success end)
        assert.is_true(wait_for(function() return unpurge_result ~= nil end, 10), "un-purge push did not complete")
        assert.is_true(unpurge_result, "un-purge push failed")

        local after_unpurge = fetch_remote_progress(sync_instance, file, test_data_dir)
        assert.is_not_nil(after_unpurge, "could not fetch remote progress after un-purge")
        assert.is_false(after_unpurge.GhostDevice.removed, "remote GhostDevice record should be un-removed")
        assert.is_true(after_unpurge.GhostDevice.timestamp >= after_purge.GhostDevice.timestamp,
            "un-purge timestamp should not be older than the purge it supersedes")

        for _, name in ipairs(sync_instance.settings.purged_devices) do
            assert.is_not_equal("GhostDevice", name, "unpurgeDevice should drop the name from purged_devices itself")
        end

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
