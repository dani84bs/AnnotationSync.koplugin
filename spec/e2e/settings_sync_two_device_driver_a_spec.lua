-- Device A half of the two-device settings-sync scenario -- run as its
-- own OS process by two_device_harness, never directly by run_e2e_tests.sh
-- (excluded from its batch; see run_e2e_tests.sh's DRIVER_EXCLUDE_PATTERN).
-- Pushes a known setting value to the real WebDAV server and exits.
describe("AnnotationSync E2E two-device settings sync (device A)", function()
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

    it("pushes device A's setting to the real WebDAV server", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_settings_sync_device_a_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write([[
return {
    ["auto_standby_timeout_seconds"] = 42
}
]])
        f:close()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.device_name = "TwoDeviceE2E-DeviceA"
        sync_instance.settings.selected_settings = {
            ["reader:auto_standby_timeout_seconds"] = true,
        }

        readerui:handleEvent(Event:new("AnnotationSyncPushSettings"))
        fastforward_ui_events()

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
