describe("AnnotationSync Sync Protection & Regressions", function()
    local ReaderUI, UIManager, Geom, SyncService
    local AnnotationSyncPlugin, highlight_db, test_utils, json
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_protection_tmp"
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
        
        highlight_db = require("spec/unit/highlight_db")
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

    it("should preserve annotations during bulk sync even if export file is missing (Issue 23)", function()
        -- 1. Create a highlight
        UIManager:show(readerui)
        readerui.rolling:onGotoPage(3)
        fastforward_ui_events()
        
        test_utils.emulate_highlight(readerui, highlight_db[1])
        assert.is_equal(1, #readerui.annotation.annotations)
        
        -- 2. Mark as dirty
        sync_instance:addToChangedDocumentsFile(readerui.document.file)
        
        -- 3. Mock sync to check what's being sent
        local last_uploaded_data
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, upload_only)
            local result = callback(local_path, local_path, local_path)
            local f = io.open(local_path, "r")
            last_uploaded_data = json.decode(f:read("*all"))
            f:close()
            return result
        end

        G_reader_settings:saveSetting("cloud_download_dir", "mock")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="mock"}))

        -- 4. Trigger Sync All
        sync_instance:syncAllChangedDocuments()
        
        -- 5. Verify the 1 highlight was found and included in the sync data
        local count = 0
        if last_uploaded_data then
            for _ in pairs(last_uploaded_data) do count = count + 1 end
        end
        assert.is_equal(1, count)
        
        SyncService.sync = old_sync
    end)

    it("should read annotations from DocSettings directly (Regression Issue 23)", function()
        local mock_ds = {
            open = function(this, file)
                return {
                    readSetting = function(self_ds, key)
                        if key == "annotations" then
                            return { { page = "test_page", pos0 = "p0", pos1 = "p1" } }
                        end
                    end
                }
            end
        }
        -- Monkey patch the instance directly if possible, or use package.loaded
        local old_ds_module = package.loaded["frontend/docsettings"]
        package.loaded["frontend/docsettings"] = mock_ds
        
        -- We need to ensure sync_instance uses the mock. 
        -- In main.lua it does: local ds = require("frontend/docsettings")
        -- Since we already initialized sync_instance, it might have captured the old one.
        -- Let's reload the plugin for this specific test to be sure.
        package.loaded["main"] = nil
        local MockPlugin = require("main")
        local mock_instance = MockPlugin:new{ ui = readerui, plugin_id = "test" }

        local result = mock_instance:getAnnotationsForDocument({ file = "any.epub" })
        assert.is_equal(1, #result)
        assert.is_equal("test_page", result[1].page)

        package.loaded["frontend/docsettings"] = old_ds_module
    end)

    it("should skip deletions if local map is empty but last sync was not (Issue 23 Protection)", function()
        local annotations_mod = require("annotations")
        local local_map = {} -- EMPTY
        local last_sync_map = {
            ["p1|p2"] = { pos0 = "p1", pos1 = "p2", text = "Gone?" }
        }
        local mock_doc = {
            compareXPointers = function() return 0 end
        }

        -- This should NOT mark anything as deleted because local_map is empty
        annotations_mod.get_deleted_annotations(local_map, last_sync_map, mock_doc)

        assert.is_equal(0, #annotations_mod.map_to_list(local_map))
        assert.is_nil(local_map["p1|p2"])
    end)
end)
