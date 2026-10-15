-- E2E regression for #107: with cloudstorage.koplugin loaded, the
-- background progress push must actually run in the subprocess instead of
-- falling back to the blocking in-process `remote.push_progress`.
-- Cloud:sync defers its round trip to UIManager:nextTick, which never fires
-- in a forked child, so routing the child through it silently fails.
describe("AnnotationSync E2E background progress push", function()
    local UIManager, ffiutil
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, remote

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        UIManager = require("ui/uimanager")
        ffiutil = require("ffi/util")
        remote = require("remote")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    local function push_progress_in_background(label, init_context)
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_push_bg_" .. label .. "_tmp"
        os.execute("rm -rf " .. test_data_dir .. " && mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local file = test_data_dir .. "/test.epub"
        ffiutil.copyFile("spec/front/unit/data/juliet.epub", file)

        local readerui, sync_instance = init_context(file, AnnotationSyncPlugin)
        UIManager:show(readerui)
        fastforward_ui_events()
        sync_instance.settings.use_filename = true
        local device_name = "BgPush-" .. label
        sync_instance.settings.device_name = device_name

        local in_process_pushes = 0
        local orig_push_progress = remote.push_progress
        remote.push_progress = function(...)
            in_process_pushes = in_process_pushes + 1
            return orig_push_progress(...)
        end

        readerui.rolling:onGotoPage(3)
        fastforward_ui_events()

        local result
        sync_instance.manager:syncProgress(function(success) result = success end)
        local deadline = os.time() + 20
        while result == nil and os.time() < deadline do
            ffiutil.usleep(200000)
            fastforward_ui_events()
        end
        remote.push_progress = orig_push_progress

        local remote_progress = e2e_test_utils.fetch_remote_progress(sync_instance, file, test_data_dir)

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil

        assert.is_true(result, "progress push did not succeed")
        assert.are.equal(0, in_process_pushes, "push_progress_bg fell back to the blocking in-process push")
        assert.is_not_nil(remote_progress, "no progress file on the remote")
        assert.is_not_nil(remote_progress[device_name], "pushed device missing from remote progress")
    end

    it("runs in the background with cloudstorage.koplugin loaded", function()
        push_progress_in_background("cloudstorage", e2e_test_utils.init_real_cloudstorage_plugin_context)
    end)

    it("runs in the background with only SyncService available", function()
        push_progress_in_background("syncservice", e2e_test_utils.init_real_remote_context)
    end)
end)
