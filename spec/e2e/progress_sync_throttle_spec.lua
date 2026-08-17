-- E2E: page-turn throttle gating background progress pushes.
--
-- Proves `progress_sync_interval` (manager.lua's `onPageUpdate`) counts
-- distinct page turns and only schedules a push once the threshold is
-- crossed -- single-device, EPUB only (page counting is format-agnostic).
-- `remote.push_progress_bg` is monkey-patched to a spy: a real
-- `dismissableRunInSubprocess` round trip needs genuine wall-clock time
-- the harness's `fastforward_ui_events()` can't inject deterministically
-- (see .scratch/e2e-coverage-hardening/research/page-turn-throttle-feasibility.md).
describe("AnnotationSync E2E progress sync throttle", function()
    local Event, UIManager, docsettings, utils
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, remote

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        UIManager = require("ui/uimanager")
        docsettings = require("docsettings")
        utils = require("utils")
        remote = require("remote")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    local function spy_push_progress_bg()
        local calls = 0
        local old_push_progress_bg = remote.push_progress_bg
        remote.push_progress_bg = function(widget, json_path, on_complete)
            calls = calls + 1
            if on_complete then on_complete(true) end
        end
        return function() return calls end, old_push_progress_bg
    end

    it("pushes once the third distinct page turn crosses the interval", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_sync_throttle_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = test_data_dir .. "/test.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", file)

        local old_getDataDir = test_utils.setup_test_env(test_data_dir)
        local old_ImageViewer_new = test_utils.mock_image_viewer()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
        sync_instance.settings.use_filename = true
        sync_instance.settings.progress_sync = true
        sync_instance.settings.progress_sync_interval = 3
        sync_instance.settings.device_name = "ThrottleE2EDevice"

        local get_push_calls, old_push_progress_bg = spy_push_progress_bg()

        -- Two distinct page turns, one short of the interval: no push.
        readerui.rolling:onGotoPage(2)
        fastforward_ui_events()
        readerui.rolling:onGotoPage(3)
        fastforward_ui_events()
        assert.is_equal(0, get_push_calls())

        -- Third distinct page turn crosses the interval: exactly one push.
        readerui.rolling:onGotoPage(4)
        fastforward_ui_events()
        -- onPageUpdate schedules the push via UIManager:scheduleIn(3, ...),
        -- so it needs its own tick beyond the one that runs it.
        fastforward_ui_events()
        assert.is_equal(1, get_push_calls())

        local sdr_dir = docsettings:getSidecarDir(file)
        local filename = sync_instance.manager:_getProgressFilename(file)
        local local_progress = utils.read_json(sdr_dir .. "/" .. filename)
        assert.is_not_nil(local_progress)
        assert.is_not_nil(local_progress["ThrottleE2EDevice"])
        assert.is_equal(4, local_progress["ThrottleE2EDevice"].page)

        remote.push_progress_bg = old_push_progress_bg
        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
