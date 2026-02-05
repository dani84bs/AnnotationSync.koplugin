describe("AnnotationSync Integration - Battery 4 (Error Handling)", function()
    local ReaderUI, UIManager, Geom, SyncService
    local AnnotationSyncPlugin, highlight_db, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_error_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        json = require("json")
        util = require("util")
        
        highlight_db = require("spec/unit/highlight_db")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))

        readerui, sync_instance = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = _G.old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end)

    before_each(function()
        UIManager:show(readerui)
        fastforward_ui_events()
        
        readerui.annotation.annotations = {}
        sync_instance.settings.network_auto_sync = false
        sync_instance.settings.use_filename = false
        sync_instance.settings.last_sync = "Never"
        
        os.remove(sync_instance.manager:changedDocumentsFile())
    end)

    describe("4.1 Network & Server Errors", function()
        it("should keep document dirty if server is offline", function()
            sync_instance.manager:addToChangedDocumentsFile(readerui.document.file)
            assert.is_true(sync_instance.manager:hasPendingChangedDocuments())

            -- Mock SyncService.sync to simulate a failure (callback never called)
            SyncService.sync = function(server, local_path, sync_cb, is_silent)
                -- Failure: callback is not called
                return 
            end

            sync_instance:manualSync()

            -- Fixed: It should now remain dirty because the callback (which triggers removal) was never called
            assert.is_true(sync_instance.manager:hasPendingChangedDocuments())
        end)

        it("should handle malformed remote data gracefully and abort upload", function()
            local income_file = test_utils.write_mock_json(test_data_dir, "malformed.json", "{ malformed json ...")

            local upload_called = false
            SyncService.sync = function(server, local_path, callback, upload_only)
                local success = callback(local_path, local_path, income_file)
                if success then
                    upload_called = true
                end
                return success
            end

            sync_instance:manualSync()
            assert.is_false(upload_called, "Sync should have aborted and not proceeded to upload")
        end)
    end)

    describe("4.2 File System Errors", function()
        it("should handle read-only sidecar directory gracefully", function()
            local docsettings = require("frontend/docsettings")
            local old_getSidecarDir = docsettings.getSidecarDir
            docsettings.getSidecarDir = function() return "/read-only-dir" end

            sync_instance:manualSync()

            docsettings.getSidecarDir = old_getSidecarDir
        end)
    end)

    describe("4.3 Concurrency", function()
        it("should handle concurrent sync requests safely", function()
            sync_instance:manualSync()
            sync_instance:manualSync()
        end)
    end)

    describe("4.4 Robustness", function()
        it("should handle special characters in highlights (Emojis)", function()
            local emoji_text = "Emoji highlight 🌟"
            local ann = {
                page = "/test/pos",
                pos0 = "/test/pos0",
                pos1 = "/test/pos1",
                text = emoji_text,
                datetime = "2026-01-01 12:00:00"
            }
            table.insert(readerui.annotation.annotations, ann)
            
            sync_instance:manualSync()
        end)
    end)
end)
