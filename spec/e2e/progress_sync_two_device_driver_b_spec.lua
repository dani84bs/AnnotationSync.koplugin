-- Device B half of the two-device progress-sync scenario -- run as its
-- own OS process by two_device_harness, after device A has already
-- pushed and exited (see progress_sync_two_device_spec.lua). Its
-- `_two_device_driver_*_spec.lua` name excludes it from
-- run_e2e_tests.sh's own batch; never run directly.
-- Pulls from the real WebDAV server and asserts the "Jump to device
-- progress" menu shows device A's page, percentage, and device label.
describe("AnnotationSync E2E two-device progress sync (device B)", function()
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

    it("sees device A's progress in the jump-to-device-progress menu", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_sync_device_b_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        -- Same basename as device A -- the remote progress filename is
        -- derived from it (use_filename), so both devices address the
        -- same remote document even though their local files live in
        -- different tmp dirs.
        local file = test_data_dir .. "/test.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", file)

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.use_filename = true
        sync_instance.settings.device_name = "TwoDeviceE2E-ProgressDeviceB"

        readerui.rolling:onGotoPage(1)
        fastforward_ui_events()

        local show_called = false
        local jump_menu_widget
        local old_show = UIManager.show
        UIManager.show = function(self, widget)
            if widget.title == "Jump to device progress" then
                show_called = true
                jump_menu_widget = widget
                return
            end
            return old_show(self, widget)
        end

        readerui:handleEvent(Event:new("AnnotationSyncJumpToDeviceProgress"))
        -- The real WebDAV round trip completes across more than one
        -- UIManager tick, same as the push side in driver A.
        fastforward_ui_events()
        fastforward_ui_events()

        UIManager.show = old_show
        assert.is_true(show_called, "jump-to-device-progress menu was never shown")

        local device_a_item
        for _, item in ipairs(jump_menu_widget.item_table) do
            if item.text:find("TwoDeviceE2E-ProgressDeviceA", 1, true) then
                device_a_item = item
            end
        end
        assert.is_not_nil(device_a_item, "device A not found in jump menu")
        assert.is_not_nil(device_a_item.text:find("Page 5", 1, true))

        -- Same formula manager.lua's saveLocalProgress and menus.lua's
        -- show_jump_menu use, against this device's own (identical) copy
        -- of the fixture -- checks the real percentage value, not just
        -- that some percentage-shaped text is present.
        local total_pages = readerui.document:getPageCount()
        local expected_pct = math.floor((5 / total_pages) * 100 + 0.5)
        assert.is_not_nil(device_a_item.text:find("(" .. expected_pct .. "%)", 1, true))

        assert.is_nil(device_a_item.text:find("this device", 1, true))

        -- Jumping via device A's entry should navigate this device there.
        device_a_item.callback()
        fastforward_ui_events()
        assert.is_equal(5, readerui:getCurrentPage())

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
