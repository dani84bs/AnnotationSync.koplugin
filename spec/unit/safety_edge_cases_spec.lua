describe("AnnotationSync Safety Edge Cases", function()
    local ReaderUI, UIManager, Geom, SyncService
    local AnnotationSyncPlugin, test_utils, json
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_safety_edge_tmp"
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

    it("should STILL propagate deletions if local list is NOT completely empty", function()
        -- 1. Mock remote state with 2 annotations
        local remote_ann = { 
            ["p1||p1"] = { 
                page = 1, pos0 = "p1", pos1 = "p1", text = "Remote 1",
                datetime_updated = "2026-01-01 00:00:00"
            },
            ["p2||p2"] = { 
                page = 2, pos0 = "p2", pos1 = "p2", text = "Remote 2",
                datetime_updated = "2026-01-01 00:00:00"
            }
        }
        
        -- 2. Mock SyncService
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, upload_only)
            local cached_path = test_data_dir .. "/cached_partial.json"
            local income_path = test_data_dir .. "/income_partial.json"
            
            local f = io.open(cached_path, "w")
            f:write(json.encode(remote_ann))
            f:close()
            
            f = io.open(income_path, "w")
            f:write(json.encode(remote_ann))
            f:close()
            
            return callback(local_path, cached_path, income_path)
        end

        G_reader_settings:saveSetting("cloud_download_dir", "mock")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="mock"}))

        -- 3. Setup local state with only 1 annotation (Remote 2 is missing)
        readerui.annotation.annotations = {
            { page = 1, pos0 = "p1", pos1 = "p1", text = "Remote 1", datetime_updated = "2026-01-01 00:00:00" }
        }
        
        -- Mock compareXPointers for string positions
        readerui.document.compareXPointers = function(self_doc, a, b)
            if a == b then return 0 end
            return a < b and 1 or -1
        end

        -- 4. Trigger Sync
        sync_instance.manager:syncDocument(readerui.document, false)
        
        -- 5. Verify local state
        -- Remote 2 should be marked as deleted now
        local sdr_dir = require("frontend/docsettings"):getSidecarDir(readerui.document.file)
        local filename = sync_instance.manager:_getAnnotationFilename(readerui.document.file)
        local json_path = sdr_dir .. "/" .. filename
        
        local f = io.open(json_path, "r")
        local saved_data = json.decode(f:read("*all"))
        f:close()
        
        assert.is_not_nil(saved_data["p2||p2"])
        assert.is_true(saved_data["p2||p2"].deleted) -- This deletion IS propagated/tracked because list wasn't empty
        
        SyncService.sync = old_sync
    end)

    it("should protect PDF annotations similarly (geometry keys)", function()
        -- 1. Setup mock remote state with PDF-style geometry keys
        local remote_ann = { 
            ["1|10|10||20|20"] = { 
                page = 1, pos0 = { x=10, y=10 }, pos1 = { x=20, y=20 }, text = "PDF Note",
                datetime_updated = "2026-01-01 00:00:00"
            }
        }
        
        -- 2. Mock SyncService
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, upload_only)
            local cached_path = test_data_dir .. "/cached_pdf.json"
            local income_path = test_data_dir .. "/income_pdf.json"
            
            local f = io.open(cached_path, "w")
            f:write(json.encode(remote_ann))
            f:close()
            
            f = io.open(income_path, "w")
            f:write(json.encode(remote_ann))
            f:close()
            
            return callback(local_path, cached_path, income_path)
        end

        G_reader_settings:saveSetting("cloud_download_dir", "mock")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="mock"}))

        -- 3. Ensure local annotations are empty
        readerui.annotation.annotations = {}
        
        -- 4. Mock document:comparePositions for PDF tables
        readerui.document.comparePositions = function() return 0 end
        
        -- 5. Trigger Sync
        sync_instance.manager:syncDocument(readerui.document, false)
        
        -- 6. Verify protection
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal("PDF Note", readerui.annotation.annotations[1].text)
        
        SyncService.sync = old_sync
    end)
end)
