describe("AnnotationSync Issue 23 Integration Reproduction", function()
    local ReaderUI, UIManager, Geom, SyncService
    local AnnotationSyncPlugin, test_utils, json
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_repro_23_tmp"
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
        
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

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

    it("should NOT delete remote annotations if local sidecar is empty (Issue 23 Reproduction)", function()
        -- 1. Setup mock remote state with 1 annotation
        local remote_ann = { 
            ["p1||p1"] = { 
                page = 1, pos0 = "p1", pos1 = "p1", text = "Remote Note",
                datetime_updated = "2026-01-01 00:00:00"
            }
        }
        
        -- 2. Mock SyncService to simulate a state where:
        -- local_file is empty (newly written by write_annotations_json)
        -- cached_file has 1 annotation (from previous sync)
        -- income_file has 1 annotation (the same one)
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, upload_only)
            -- We create a cached file and an income file
            local cached_path = test_data_dir .. "/cached.json"
            local income_path = test_data_dir .. "/income.json"
            
            local f = io.open(cached_path, "w")
            f:write(json.encode(remote_ann))
            f:close()
            
            f = io.open(income_path, "w")
            f:write(json.encode(remote_ann))
            f:close()
            
            -- Trigger the callback
            local result = callback(local_path, cached_path, income_path)
            return result
        end

        G_reader_settings:saveSetting("cloud_download_dir", "mock")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="mock"}))

        -- 3. Ensure local annotations are empty
        readerui.annotation.annotations = {}
        
        -- 4. Trigger Sync
        sync_instance.manager:syncDocument(readerui.document, false) -- NOT forced
        
        -- 5. Verify local state
        -- If safety works, the remote annotation should be back in local list
        -- AND it should NOT be marked as deleted in the local JSON.
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal("Remote Note", readerui.annotation.annotations[1].text)
        
        -- Check the actual JSON file written back to disk
        local sdr_dir = require("frontend/docsettings"):getSidecarDir(readerui.document.file)
        local filename = sync_instance.manager:_getAnnotationFilename(readerui.document.file)
        local json_path = sdr_dir .. "/" .. filename
        
        local f = io.open(json_path, "r")
        local saved_data = json.decode(f:read("*all"))
        f:close()
        
        assert.is_not_nil(saved_data["p1||p1"])
        assert.is_nil(saved_data["p1||p1"].deleted) -- Should NOT be deleted
        
        SyncService.sync = old_sync
    end)
end)
