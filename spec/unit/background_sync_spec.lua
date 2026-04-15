describe("Background Sync Behavior", function()
    local SyncService, UIManager, Trapper
    local remote, json, test_utils
    local test_data_dir = os.getenv("PWD") .. "/test_bg_sync_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        SyncService = require("apps/cloudstorage/syncservice")
        UIManager = require("ui/uimanager")
        Trapper = require("ui/trapper")
        json = require("json")
        
        test_utils = require("spec/unit/test_utils")
        remote = require("remote")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))
    end)

    teardown(function()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        package.loaded["remote"] = nil
    end)

    before_each(function()
        -- Mock Trapper
        Trapper.wrap = function(this, func)
            func()
        end
        Trapper.dismissableRunInSubprocess = function(this, func, is_blocking)
            local success = func()
            return true, success
        end

        -- Mock SyncService
        SyncService.sync = function(server, local_path, callback, upload_only)
            return callback(local_path, local_path, local_path)
        end

        -- Mock UIManager:show to detect notifications
        UIManager.show = spy.new(function() end)
    end)

    it("push_progress_bg uses Trapper for background execution", function()
        local wrap_called = false
        local subprocess_called = false
        
        Trapper.wrap = function(this, func)
            wrap_called = true
            func()
        end
        Trapper.dismissableRunInSubprocess = function(this, func, is_blocking)
            subprocess_called = true
            local success = func()
            return true, success
        end

        local on_complete_called = false
        remote.push_progress_bg("dummy.json", function(success)
            on_complete_called = true
            assert.is_true(success)
        end)

        assert.is_true(wrap_called)
        assert.is_true(subprocess_called)
        assert.is_true(on_complete_called)
    end)

    it("push_progress_bg fails silently (no UI) on error", function()
        -- Simulate sync failure
        SyncService.sync = function(server, local_path, callback, upload_only)
            return false
        end

        local on_complete_called = false
        remote.push_progress_bg("dummy.json", function(success)
            on_complete_called = true
            assert.is_false(success)
        end)

        assert.is_true(on_complete_called)
        -- Verify no InfoMessage was shown
        assert.spy(UIManager.show).was_not_called()
    end)

    it("pull_progress remains synchronous and does NOT use Trapper", function()
        local wrap_called = false
        Trapper.wrap = function(this, func)
            wrap_called = true
            func()
        end

        remote.pull_progress("dummy.json", function(success)
            assert.is_true(success)
        end)

        assert.is_false(wrap_called)
    end)

    it("sync_annotations remains synchronous and does NOT use Trapper", function()
        local wrap_called = false
        Trapper.wrap = function(this, func)
            wrap_called = true
            func()
        end

        -- Mock annotations.sync_callback
        local annotations = require("annotations")
        local old_sync_callback = annotations.sync_callback
        annotations.sync_callback = function() return true, {} end

        remote.sync_annotations({}, {}, "dummy.json", function(success)
            assert.is_true(success)
        end)

        assert.is_false(wrap_called)
        annotations.sync_callback = old_sync_callback
    end)

    it("push_progress_bg handles subprocess crash/interruption", function()
        Trapper.dismissableRunInSubprocess = function(this, func, is_blocking)
            -- completed = false, success = nil
            return false, nil
        end

        local on_complete_called = false
        remote.push_progress_bg("dummy.json", function(success)
            on_complete_called = true
            assert.is_false(success)
        end)

        assert.is_true(on_complete_called)
    end)
end)
