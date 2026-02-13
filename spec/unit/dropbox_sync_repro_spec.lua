describe("Dropbox Sync Reproduction", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, highlight_db, test_utils, json, util, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_dropbox_sync_tmp"
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
        annotations_mod = require("annotations")
        
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        os.execute("mkdir -p " .. test_data_dir .. "/plugins")

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-dropbox")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-dropbox", type="dropbox"}))

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

    it("verifies that Dropbox 'path not found' error is now handled gracefully", function()
        -- 1. Setup a "changed" document
        sync_instance.manager:addToChangedDocumentsFile(readerui.document.file)
        
        -- 2. Mock SyncService to return the Dropbox error JSON in income_file
        local dropbox_error = {
            error_summary = "path/not_found/.",
            error = {
                [".tag"] = "path",
                path = { [".tag"] = "not_found" }
            }
        }
        
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            local income_file = local_path .. ".temp"
            local f = io.open(income_file, "w")
            f:write(json.encode(dropbox_error))
            f:close()
            
            local cached_file = local_path .. ".sync"
            -- Create empty cached file if not exists
            if not io.open(cached_file, "r") then
                local fc = io.open(cached_file, "w")
                fc:write("{}")
                fc:close()
            end

            local success = callback(local_path, cached_file, income_file)
            os.remove(income_file)
            return success
        end

        -- 3. Run sync
        local success = sync_instance.manager:syncDocument(readerui.document, true)

        -- 4. Verify success
        assert.is_true(success, "Sync should now succeed by treating Dropbox path/not_found as empty state")
        
        SyncService.sync = old_sync
    end)
end)
