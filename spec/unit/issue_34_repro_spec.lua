describe("Issue #34 Reproduction & Fix Verification", function()
    local ReaderUI, UIManager, SyncService, Geom, HTTPClient
    local AnnotationSyncPlugin, highlight_db, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_issue_34_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        HTTPClient = require("httpclient")
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

    it("verifies that Sync All no longer reports false success on push failure", function()
        -- 1. Setup a "changed" document
        sync_instance.manager:addToChangedDocumentsFile(readerui.document.file)
        
        -- 2. Mock SyncService to fail
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            -- Simulate failure by NOT calling the callback
            return nil 
        end

        -- 3. Run Sync All
        local messages = {}
        local old_show_msg = require("utils").show_msg
        require("utils").show_msg = function(msg)
            table.insert(messages, msg)
        end

        sync_instance.manager:syncAllChangedDocuments()

        -- 4. Verify that it reports failure (0 successes)
        local failure_msg = "Unable to sync modified documents: 1"
        local found = false
        for _, m in ipairs(messages) do
            if m == failure_msg then found = true break end
        end
        
        SyncService.sync = old_sync
        require("utils").show_msg = old_show_msg

        assert.is_true(found, "Sync All should have reported failure when sync failed")
        
        local count, _ = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(1, count, "Document should still be pending if sync failed")
    end)

    it("verifies sidecar directory creation for new books", function()
        -- 1. Setup a "changed" document and ensure its sidecar dir is GONE
        local file = readerui.document.file
        sync_instance.manager:addToChangedDocumentsFile(file)
        local sdr_dir = require("frontend/docsettings"):getSidecarDir(file)
        os.execute("rm -rf " .. sdr_dir)
        
        local lfs = require("libs/libkoreader-lfs")
        assert.is_nil(lfs.attributes(sdr_dir), "Sidecar directory should be missing for test")

        -- 2. Mock SyncService to simulate success
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            callback(local_path, local_path, local_path)
            return 200 -- Success
        end

        -- 3. Run Sync All
        sync_instance.manager:syncAllChangedDocuments()

        -- 4. Verify that the directory was created
        assert.is_not_nil(lfs.attributes(sdr_dir), "Sidecar directory should have been created automatically")
        
        SyncService.sync = old_sync
        local count, _ = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(0, count, "Document should have been successfully synced")
    end)

    it("verifies that 404 error bodies (non-JSON) are handled gracefully", function()
        -- 1. Setup a "changed" document
        sync_instance.manager:addToChangedDocumentsFile(readerui.document.file)

        -- 2. Mock SyncService to simulate a 404 with a non-JSON body
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            -- Create a .temp file with "Not Found" (non-JSON)
            local income_file = local_path .. ".temp"
            local f = io.open(income_file, "w")
            f:write("Not Found")
            f:close()
            
            -- Call the callback
            local cached_file = local_path .. ".sync"
            local success = callback(local_path, cached_file, income_file)
            
            os.remove(income_file)
            return success and 200 or 500
        end

        -- 3. Run Sync All
        sync_instance.manager:syncAllChangedDocuments()

        -- 4. Verify that it succeeded (didn't abort on invalid JSON)
        SyncService.sync = old_sync
        local count, _ = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(0, count, "Sync should have succeeded by treating 404 body as empty state")
    end)
end)
