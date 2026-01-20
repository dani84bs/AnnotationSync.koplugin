describe("AnnotationSync Automation & Settings", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, highlight_db, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_automation_tmp"
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
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server"}))

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
        os.remove(sync_instance:changedDocumentsFile())
    end)

    describe("Settings", function()
        it("respects naming convention settings", function()
            test_utils.emulate_highlight(readerui, highlight_db[1])

            local captured_path
            SyncService.sync = function(server, local_path, callback, upload_only)
                captured_path = local_path
                callback(local_path, local_path, local_path)
            end

            sync_instance.settings.use_filename = false
            sync_instance:manualSync()
            assert.truthy(captured_path:match(util.partialMD5(readerui.document.file) .. "%.json$"))

            sync_instance.settings.use_filename = true
            sync_instance:manualSync()
            assert.truthy(captured_path:match("juliet%.epub%.json$"))
        end)
    end)

    describe("Automation", function()
        it("triggers sync on NetworkConnected", function()
            sync_instance.settings.network_auto_sync = true
            sync_instance:registerEvents()
            sync_instance:addToChangedDocumentsFile(readerui.document.file)

            local sync_triggered = false
            SyncService.sync = function(server, local_path, callback, upload_only)
                sync_triggered = true
                callback(local_path, local_path, local_path)
            end
            
            local old_schedule = UIManager.scheduleIn
            UIManager.scheduleIn = function(self_ui, time, callback) callback() end

            sync_instance:onNetworkConnected()

            assert.is_true(sync_triggered)
            UIManager.scheduleIn = old_schedule
        end)

        it("batch processes multiple documents correctly", function()
            local doc1 = readerui.document.file
            local doc2 = "spec/front/unit/data/leaves.epub"
            
            sync_instance:addToChangedDocumentsFile(doc1)
            sync_instance:addToChangedDocumentsFile(doc2)
            
            local synced_files = {}
            SyncService.sync = function(server, local_path, callback, upload_only)
                table.insert(synced_files, local_path)
                callback(local_path, local_path, local_path)
            end

            local old_getDoc = sync_instance.getDocumentByFile
            sync_instance.getDocumentByFile = function(this, file)
                if file == doc1 then return readerui.document end
                return { 
                    file = file, provider = "crengine", render = function() end,
                    compareXPointers = function(self_doc, a, b) return 0 end
                }
            end
            
            sync_instance:syncAllChangedDocuments()
            assert.is_equal(2, #synced_files)
            
            sync_instance.getDocumentByFile = old_getDoc
        end)
    end)
end)
