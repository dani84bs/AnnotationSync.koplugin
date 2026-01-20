describe("AnnotationSync Sync Protection & Regressions", function()
    local ReaderUI, UIManager, Geom
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
        local SyncService = require("apps/cloudstorage/syncservice")
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, upload_only)
            callback(local_path, local_path, local_path)
            local f = io.open(local_path, "r")
            last_uploaded_data = json.decode(f:read("*all"))
            f:close()
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
        -- Mock docsettings module in package.loaded
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
        local old_fds = package.loaded["frontend/docsettings"]
        local old_ds = package.loaded["docsettings"]
        
        package.loaded["frontend/docsettings"] = mock_ds
        package.loaded["docsettings"] = mock_ds

        -- We must reload the plugin to pick up the mocked docsettings
        package.loaded["main"] = nil
        local MockPlugin = require("main")
        local mock_instance = MockPlugin:new{ ui = readerui, plugin_id = "test" }

        local result = mock_instance:getAnnotationsForDocument({ file = "any.epub" })
        assert.is_equal(1, #result)
        assert.is_equal("test_page", result[1].page)

        package.loaded["frontend/docsettings"] = old_fds
        package.loaded["docsettings"] = old_ds
    end)
end)
