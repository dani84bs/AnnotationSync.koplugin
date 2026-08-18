-- Repro attempt for GitHub #85: reporter claims that renaming a device
-- (changing settings.device_name) makes subsequent reading-progress pushes
-- fail. Static tracing of push_progress_bg/_sync_progress_callback found
-- no device_name-specific failure path -- this drives an actual push
-- before and after a rename against the real local WebDAV server to check
-- whether that holds up, or whether something only visible at runtime
-- (subprocess push, real HTTP round-trip) explains the report.
describe("AnnotationSync E2E progress push after device rename (issue #85 repro)", function()
    local Event, ReaderUI, UIManager
    local AnnotationSyncPlugin, test_utils, e2e_test_utils

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("still pushes successfully after the device is renamed", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_rename_repro_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local file = test_data_dir .. "/test.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", file)

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.use_filename = true
        sync_instance.settings.device_name = "RenameRepro-Before"

        -- First push, under the original device name.
        readerui.rolling:onGotoPage(5)
        fastforward_ui_events()

        local first_result
        sync_instance.manager:syncProgress(function(success) first_result = success end)
        local deadline = os.time() + 10
        while first_result == nil and os.time() < deadline do
            require("ffi/util").sleep(0.2)
            fastforward_ui_events()
        end
        assert.is_true(first_result, "first push (before rename) failed")

        -- Rename the device, then push again -- this is the step the
        -- reporter says breaks the push.
        sync_instance.settings.device_name = "RenameRepro-After"
        readerui.rolling:onGotoPage(10)
        fastforward_ui_events()

        local second_result
        sync_instance.manager:syncProgress(function(success) second_result = success end)
        deadline = os.time() + 10
        while second_result == nil and os.time() < deadline do
            require("ffi/util").sleep(0.2)
            fastforward_ui_events()
        end
        assert.is_true(second_result, "second push (after rename) failed -- reproduces #85")

        -- Inspect what actually landed remotely: both device keys should
        -- be present since the merge is additive (see #85/#90 root cause).
        local WebDavApi = require("apps/cloudstorage/webdavapi")
        local server = e2e_test_utils.server_config()
        local filename = sync_instance.manager:_getProgressFilename(file)
        local remote_path = WebDavApi:getJoinedPath(server.address, server.url)
        remote_path = WebDavApi:getJoinedPath(remote_path, filename)
        local tmp_path = test_data_dir .. "/.fetch_remote_progress.json"
        local code = WebDavApi:downloadFile(remote_path, server.username, server.password, tmp_path)
        assert.is_true(code ~= nil and code >= 200 and code < 300, "could not fetch remote progress after rename")
        local f = io.open(tmp_path, "r")
        local content = f:read("*a")
        f:close()
        os.remove(tmp_path)
        local json = require("json")
        local ok, data = pcall(json.decode, content)
        assert.is_true(ok, "remote progress JSON did not parse")

        assert.is_not_nil(data["RenameRepro-Before"], "old device-name key missing from remote progress")
        assert.is_not_nil(data["RenameRepro-After"], "new device-name key missing from remote progress")

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
