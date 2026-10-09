describe("Background Sync Behavior", function()
    local SyncService, UIManager, Trapper, ffiutil
    local remote, json, test_utils
    local test_data_dir = os.getenv("PWD") .. "/test_bg_sync_tmp"
    local old_getDataDir
    local real_run_in_background

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        SyncService = require("apps/cloudstorage/syncservice")
        UIManager = require("ui/uimanager")
        Trapper = require("ui/trapper")
        ffiutil = require("ffi/util")
        json = require("json")

        test_utils = require("spec/unit/test_utils")
        remote = require("remote")
        real_run_in_background = remote._run_in_background

        old_getDataDir = test_utils.setup_test_env(test_data_dir)

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))
    end)

    teardown(function()
        remote._run_in_background = real_run_in_background
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        package.loaded["remote"] = nil
    end)

    local mock_widget
    local background_runs

    before_each(function()
        -- Run the background task inline: forking is covered by its own test below.
        background_runs = 0
        remote._run_in_background = function(task, on_done)
            background_runs = background_runs + 1
            on_done(task())
        end

        -- Mock Trapper
        Trapper.wrap = spy.new(function(this, func)
            func()
        end)
        Trapper.dismissableRunInSubprocess = spy.new(function(this, func)
            return true, func()
        end)

        -- Mock SyncService
        SyncService.sync = spy.new(function(server, local_path, callback, upload_only)
            return callback(local_path, local_path, local_path)
        end)

        -- Mock UIManager:show to detect notifications
        UIManager.show = spy.new(function() end)

        mock_widget = {
            ui = {
                cloudstorage = {
                    sync = spy.new(function(self, server, file_path, sync_cb, is_silent)
                        return sync_cb(file_path, file_path, file_path)
                    end)
                }
            },
            settings = {
                sync_server = { url = "http://mock-server", type = "webdav" }
            }
        }
    end)

    it("push_progress_bg runs the push in a background subprocess", function()
        local on_complete_called = false
        remote.push_progress_bg(mock_widget, "dummy.json", function(success)
            on_complete_called = true
            assert.is_true(success)
        end)

        assert.are.equal(1, background_runs)
        assert.spy(SyncService.sync).was_called(1)
        assert.is_true(on_complete_called)
    end)

    it("push_progress_bg does not trap input while syncing", function()
        remote.push_progress_bg(mock_widget, "dummy.json", function() end)

        assert.spy(Trapper.wrap).was_not_called()
        assert.spy(Trapper.dismissableRunInSubprocess).was_not_called()
    end)

    it("push_progress_bg uses SyncService in the child, not the deferred cloudstorage sync", function()
        -- cloudstorage.koplugin's Cloud:sync defers its work to UIManager:nextTick,
        -- which never runs in a subprocess without a UI loop.
        remote.push_progress_bg(mock_widget, "dummy.json", function() end)

        assert.spy(SyncService.sync).was_called(1)
        assert.spy(mock_widget.ui.cloudstorage.sync).was_not_called()
    end)

    it("push_progress_bg pushes in-process when no synchronous backend handles the server", function()
        mock_widget.settings.sync_server = { url = "/", type = "ftp" }

        local on_complete_called = false
        remote.push_progress_bg(mock_widget, "dummy.json", function(success)
            on_complete_called = true
            assert.is_true(success)
        end)

        assert.are.equal(0, background_runs)
        assert.spy(mock_widget.ui.cloudstorage.sync).was_called(1)
        assert.is_true(on_complete_called)
    end)

    it("push_progress_bg fails silently (no UI) on error", function()
        -- Simulate sync failure
        SyncService.sync = function(server, local_path, callback, upload_only)
            return false
        end

        local on_complete_called = false
        remote.push_progress_bg(mock_widget, "dummy.json", function(success)
            on_complete_called = true
            assert.is_false(success)
        end)

        assert.is_true(on_complete_called)
        -- Verify no InfoMessage was shown
        assert.spy(UIManager.show).was_not_called()
    end)

    it("pull_progress remains synchronous and does NOT use Trapper", function()
        remote.pull_progress(mock_widget, "dummy.json", function(success)
            assert.is_true(success)
        end)

        assert.spy(Trapper.wrap).was_not_called()
    end)

    it("sync_annotations remains synchronous and does NOT use Trapper", function()
        -- Mock annotations.sync_callback
        local annotations = require("annotations")
        local old_sync_callback = annotations.sync_callback
        annotations.sync_callback = function() return true, {} end

        remote.sync_annotations(mock_widget, {}, "dummy.json", function(success)
            assert.is_true(success)
        end)

        assert.spy(Trapper.wrap).was_not_called()
        annotations.sync_callback = old_sync_callback
    end)

    it("push_progress_bg handles subprocess crash/interruption", function()
        remote._run_in_background = function(task, on_done)
            on_done(nil)
        end

        local on_complete_called = false
        remote.push_progress_bg(mock_widget, "dummy.json", function(success)
            on_complete_called = true
            assert.is_false(success)
        end)

        assert.is_true(on_complete_called)
    end)

    it("_run_in_background returns without waiting for the child", function()
        local result
        real_run_in_background(function()
            ffiutil.sleep(0.3)
            return "ok"
        end, function(r)
            result = r
        end)

        -- The caller is not blocked: nothing has been reported yet.
        assert.is_nil(result)

        local deadline = os.time() + 10
        while result == nil and os.time() < deadline do
            ffiutil.sleep(0.1)
            fastforward_ui_events()
        end
        assert.are.equal("ok", result)
    end)
end)
