-- Device B half of the two-device settings-sync scenario -- run as its
-- own OS process by two_device_harness, after device A has already
-- pushed and exited (see settings_sync_two_device_spec.lua). Its
-- `_two_device_driver_*_spec.lua` name excludes it from
-- run_e2e_tests.sh's own batch; never run directly.
-- Pulls from the real WebDAV server and asserts device A's setting
-- (auto_standby_timeout_seconds = 42) is visible and importable.
describe("AnnotationSync E2E two-device settings sync (device B)", function()
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

    it("pulls device A's setting from the real WebDAV server", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_settings_sync_device_b_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        -- Device B's own current value for the same setting, deliberately
        -- different from device A's so the pull surfaces a real diff.
        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write([[
return {
    ["auto_standby_timeout_seconds"] = 7
}
]])
        f:close()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.device_name = "TwoDeviceE2E-DeviceB"

        local show_called_count = 0
        local old_show = UIManager.show
        UIManager.show = function(self, widget)
            if widget.text and not widget.title then
                return old_show(self, widget)
            end
            show_called_count = show_called_count + 1
            if show_called_count == 1 then
                assert.is_equal("Pull settings from cloud", widget.title)
                assert.is_equal(1, #widget.item_table)
                assert.is_not_nil(widget.item_table[1].text:find("TwoDeviceE2E-DeviceA"))
                widget.item_table[1].callback()
            elseif show_called_count == 2 then
                assert.is_not_nil(widget.title:find("TwoDeviceE2E-DeviceA"))
                local found_setting = false
                for _, item in ipairs(widget.item_table) do
                    if item.text_func and item.text_func():find("auto_standby_timeout_seconds", 1, true) then
                        found_setting = true
                        assert.is_not_nil(item.text_func():find("7 %-> 42"))
                    end
                end
                assert.is_true(found_setting)
                -- First item is the bold "Import Selected Settings" action.
                widget.item_table[1].callback()
            end
        end

        readerui:handleEvent(Event:new("AnnotationSyncPullSettings"))
        fastforward_ui_events()

        UIManager.show = old_show
        assert.is_equal(2, show_called_count)

        local ok_read, data = pcall(dofile, test_data_dir .. "/settings.reader.lua")
        assert.is_true(ok_read)
        assert.is_equal(42, data.auto_standby_timeout_seconds)

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
