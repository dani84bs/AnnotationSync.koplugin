describe("Asynchronous Sync Reproduction Test", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_repro_async_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        json = require("json")
        util = require("util")
        
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        os.execute("mkdir -p " .. test_data_dir .. "/plugins")

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))

        readerui, sync_instance = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)

    before_each(function()
        os.remove(sync_instance.manager:changedDocumentsFile())
    end)

    it("reproduces the crash when sync callback is executed after temporary document is closed", function()
        local file = test_data_dir .. "/temp_book.epub"
        
        -- Create a dummy file for the book
        local f = io.open(file, "w")
        f:write("dummy")
        f:close()

        -- Set up changed document
        sync_instance.manager:addToChangedDocumentsFile(file)

        -- Mock getDocumentByFile to return a mock document that throws when used after closed
        local is_closed = false
        local mock_document = {
            file = file,
            compareXPointers = function(this, a, b)
                if is_closed then
                    error("Attempted to use closed document!")
                end
                return 0
            end,
            close = function(this)
                is_closed = true
            end
        }

        local old_getDoc = sync_instance.manager.getDocumentByFile
        sync_instance.manager.getDocumentByFile = function(this, path)
            if path == file then
                return mock_document
            end
            return old_getDoc(this, path)
        end

        -- Mock cloudstorage to be asynchronous
        local captured_callback = nil
        local captured_local_file = nil
        local captured_cached_file = nil
        local captured_income_file = nil
        
        local old_cloudstorage = readerui.cloudstorage
        readerui.cloudstorage = {
            sync = function(this, server, local_path, callback, is_silent)
                captured_callback = callback
                captured_local_file = local_path
                captured_cached_file = local_path .. ".sync"
                captured_income_file = local_path .. ".temp"
                
                -- Create mock annotations to trigger compareXPointers
                local local_ann = {
                    ["/html/body/p[1]||/html/body/p[2]"] = {
                        page = 1,
                        pos0 = "/html/body/p[1]",
                        pos1 = "/html/body/p[2]",
                        text = "Hello local",
                        datetime_updated = "2026-06-18 12:00:00"
                    }
                }
                local income_ann = {
                    ["/html/body/p[3]||/html/body/p[4]"] = {
                        page = 1,
                        pos0 = "/html/body/p[3]",
                        pos1 = "/html/body/p[4]",
                        text = "Hello remote",
                        datetime_updated = "2026-06-18 12:05:00"
                    }
                }

                local f1 = io.open(captured_local_file, "w")
                f1:write(json.encode(local_ann))
                f1:close()
                local f2 = io.open(captured_cached_file, "w")
                f2:write(json.encode(local_ann))
                f2:close()
                local f3 = io.open(captured_income_file, "w")
                f3:write(json.encode(income_ann))
                f3:close()
                
                -- Asynchronous behavior: we return immediately without invoking callback!
                return true
            end
        }

        -- Run sync all
        sync_instance.manager:syncAllChangedDocuments()

        -- Verify that the temporary document is NOT closed after syncAllChangedDocuments returns (kept open for async sync)
        assert.is_false(is_closed, "Temporary document should not be closed while sync is in progress")

        -- Now execute the captured callback (simulating remote sync completing asynchronously)
        assert.is_not_nil(captured_callback, "Callback should be captured")
        
        -- This should succeed because document is still open
        local success = captured_callback(captured_local_file, captured_cached_file, captured_income_file)
        assert.is_true(success, "Callback should succeed since document is open")

        -- Now verify that the document is closed AFTER the callback finishes
        assert.is_true(is_closed, "Temporary document should be closed after async callback completes")

        -- Clean up
        sync_instance.manager.getDocumentByFile = old_getDoc
        readerui.cloudstorage = old_cloudstorage
        os.remove(file)
    end)
end)
