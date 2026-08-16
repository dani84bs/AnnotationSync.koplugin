-- Device A half of the two-device progress-sync scenario -- run as its
-- own OS process by two_device_harness, never directly by
-- run_e2e_tests.sh (its `_two_device_driver_*_spec.lua` name excludes it
-- from that batch). Reaches page 5, pushes progress to the real WebDAV
-- server, and exits.
describe("AnnotationSync E2E two-device progress sync (device A)", function()
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

    it("pushes device A's reading progress to the real WebDAV server", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_sync_device_a_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local file = test_data_dir .. "/test.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", file)

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        -- use_filename: the remote progress filename must match across
        -- devices even though each device copies the fixture into its own
        -- tmp dir -- a path hash would differ, a shared basename won't.
        sync_instance.settings.use_filename = true
        sync_instance.settings.device_name = "TwoDeviceE2E-ProgressDeviceA"

        readerui.rolling:onGotoPage(5)
        fastforward_ui_events()

        readerui:handleEvent(Event:new("AnnotationSyncPushProgress"))
        fastforward_ui_events()
        fastforward_ui_events()

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
