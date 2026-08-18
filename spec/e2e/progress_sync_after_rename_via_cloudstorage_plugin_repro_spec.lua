-- Continued investigation for GH-90's still-unconfirmed second symptom:
-- lychee128 reports an actual error message ("Fetching remote progress..."
-- then "Something went wrong") after renaming devices, not a hang, and it
-- recovers temporarily after switching cloud folders. Every prior repro
-- (the original gh-85 one, and issue_90_pull_retry_bound/persistent_conflict
-- specs) drove apps/cloudstorage/syncservice.lua's SyncService.sync via the
-- has_syncservice fallback -- never the real cloudstorage.koplugin Cloud:sync
-- path that remote.get_sync_provider actually prefers for anyone with the
-- Cloud Storage plugin enabled. This drives push AND pull (the "jump to
-- device" flow, which is what actually shows "Fetching remote progress...")
-- through that real path, with several renamed/accumulated devices, to see
-- whether the real path fails where the fallback didn't.
describe("AnnotationSync E2E progress sync after device rename via real cloudstorage.koplugin (issue #90 continued repro)", function()
    local ReaderUI, UIManager
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, utils

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        utils = require("utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("pushes and pulls successfully across several renames, on the real cloudstorage.koplugin path", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_progress_rename_cloudstorage_repro_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local file = test_data_dir .. "/test.epub"
        require("ffi/util").copyFile("spec/front/unit/data/juliet.epub", file)

        local readerui, sync_instance = e2e_test_utils.init_real_cloudstorage_plugin_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.use_filename = true

        local shown_messages = {}
        local old_show_msg = utils.show_msg
        utils.show_msg = function(msg)
            table.insert(shown_messages, tostring(msg))
            return old_show_msg(msg)
        end

        local function push_and_wait(device_name, page)
            sync_instance.settings.device_name = device_name
            readerui.rolling:onGotoPage(page)
            fastforward_ui_events()

            local result
            sync_instance.manager:syncProgress(function(success) result = success end)
            local deadline = os.time() + 10
            while result == nil and os.time() < deadline do
                require("ffi/util").sleep(0.2)
                fastforward_ui_events()
            end
            return result
        end

        -- Simulate lychee128's setup: several devices, each renamed once,
        -- each pushing in turn -- accumulating stale entries the same way
        -- the confirmed additive-merge bug does in production.
        local names = { "Kindle1", "Kindle1b", "Kindle2", "Kindle2b", "Kindle3" }
        local results = {}
        for i, name in ipairs(names) do
            results[name] = push_and_wait(name, i + 1)
        end

        for name, ok in pairs(results) do
            assert.is_true(ok, "push under device name '" .. name .. "' failed on the real cloudstorage.koplugin path")
        end

        -- "Jump to other devices" -- this is the actual flow that shows
        -- "Fetching remote progress..." (manager.lua:284), the message
        -- lychee128 says precedes their failure.
        sync_instance.manager:pullProgress()
        fastforward_ui_events()
        local deadline = os.time() + 10
        while os.time() < deadline do
            local found_terminal = false
            for _, msg in ipairs(shown_messages) do
                if msg:find("Failed to fetch remote progress") then found_terminal = true end
            end
            if found_terminal then break end
            require("ffi/util").sleep(0.2)
            fastforward_ui_events()
        end

        utils.show_msg = old_show_msg

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil

        local failure_msg
        for _, msg in ipairs(shown_messages) do
            if msg:find("Failed to fetch remote progress") or msg:find("went wrong") or msg:find("Something went wrong") then
                failure_msg = msg
            end
        end
        assert.is_nil(failure_msg, "reproduced a failure message on the real path: " .. tostring(failure_msg) ..
            " -- all messages: " .. table.concat(shown_messages, " | "))
    end)
end)
