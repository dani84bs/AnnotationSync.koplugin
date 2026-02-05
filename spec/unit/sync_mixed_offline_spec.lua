describe("AnnotationSync Mixed Documents & Offline Sync All", function()
    local ReaderUI, UIManager, SyncService, Geom, DataStorage
    local AnnotationSyncPlugin, highlight_db, highlight_pdf_db, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_mixed_offline_tmp"
    local old_getDataDir
    local sample_epub = "spec/front/unit/data/juliet.epub"
    local sample_pdf_src = "spec/front/unit/data/sample.pdf"
    local sample_pdf_dest

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        DataStorage = require("datastorage")
        json = require("json")
        util = require("util")
        annotations_mod = require("annotations")
        
        highlight_db = require("spec/unit/highlight_db")
        highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        sample_pdf_dest = DataStorage:getDataDir() .. "/test.pdf"
        require("ffi/util").copyFile(sample_pdf_src, sample_pdf_dest)

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server"}))

        -- Start with EPUB open
        readerui, sync_instance = test_utils.init_integration_context(
            sample_epub, AnnotationSyncPlugin
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
        os.remove(sync_instance.manager:changedDocumentsFile())
        test_utils.mock_sync_service(SyncService)
    end)

    it("Sync All processes both dirty EPUB and PDF and they stay dirty if offline", function()
        local doc_epub = sample_epub
        local doc_pdf = sample_pdf_dest
        
        -- 1. Mark both as dirty
        sync_instance.manager:addToChangedDocumentsFile(doc_epub)
        sync_instance.manager:addToChangedDocumentsFile(doc_pdf)
        
        assert.is_equal(2, (select(1, sync_instance.manager:getPendingChangedDocuments())))

        -- 2. Mock OFFLINE server (callback never called)
        local sync_calls = 0
        SyncService.sync = function(server, local_path, callback, upload_only)
            sync_calls = sync_calls + 1
            -- OFFLINE: we don't call the callback
            return
        end

        -- 3. Trigger Sync All
        sync_instance.manager:syncAllChangedDocuments()
        
        -- Should have attempted to sync both
        assert.is_equal(2, sync_calls)
        
        -- 4. Verify both remain dirty because sync failed (callback never called)
        local count, changed_docs = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(2, count)
        assert.truthy(changed_docs[doc_epub])
        assert.truthy(changed_docs[doc_pdf])

        -- 5. Mock ONLINE server
        SyncService.sync = function(server, local_path, callback, upload_only)
            return callback(local_path, local_path, local_path)
        end

        -- 6. Trigger Sync All again
        sync_instance.manager:syncAllChangedDocuments()
        
        -- 7. Verify both are now clean
        assert.is_equal(0, (select(1, sync_instance.manager:getPendingChangedDocuments())))
    end)

    it("Sync All performs full bidirectional merge for both mixed document types", function()
        local doc_epub = sample_epub
        local doc_pdf = sample_pdf_dest
        
        -- 1. Prepare EPUB (Active)
        readerui.rolling:onGotoPage(3)
        fastforward_ui_events()
        test_utils.emulate_highlight(readerui, highlight_db[1])
        local ann_epub_l = readerui.annotation.annotations[1]
        ann_epub_l.datetime = "2026-02-01 10:00:00"
        
        -- Remote EPUB addition
        local ann_epub_r = util.tableDeepCopy(ann_epub_l)
        ann_epub_r.pos0 = highlight_db[2].p0
        ann_epub_r.pos1 = highlight_db[2].p1
        ann_epub_r.text = highlight_db[2].text
        ann_epub_r.datetime = "2026-02-01 11:00:00"
        local key_epub_r = annotations_mod.annotation_key(ann_epub_r)
        
        -- 2. Prepare PDF (Inactive)
        -- We need to manually add it to changed docs and put something in its sidecar
        local ds_pdf = require("frontend/docsettings"):open(doc_pdf)
        local ann_pdf_l = {
            page = 10,
            pos0 = util.tableDeepCopy(highlight_pdf_db[1].pos0),
            pos1 = util.tableDeepCopy(highlight_pdf_db[1].pos1),
            text = highlight_pdf_db[1].text,
            datetime = "2026-02-01 10:00:00",
            note = "Local PDF"
        }
        ann_pdf_l.pos0.page = 10
        ann_pdf_l.pos1.page = 10
        ds_pdf:saveSetting("annotations", { ann_pdf_l })
        ds_pdf:flush()
        sync_instance.manager:addToChangedDocumentsFile(doc_pdf)
        
        -- Remote PDF addition
        local ann_pdf_r = util.tableDeepCopy(ann_pdf_l)
        ann_pdf_r.pos0.x = ann_pdf_r.pos0.x + 200 -- different highlight
        ann_pdf_r.pos1.x = ann_pdf_r.pos1.x + 200
        ann_pdf_r.text = "Remote PDF"
        ann_pdf_r.datetime = "2026-02-01 11:00:00"
        local key_pdf_r = annotations_mod.annotation_key(ann_pdf_r)

        -- 3. Mock remote files
        local income_epub = test_utils.write_mock_json(test_data_dir, "income_epub.json", { [key_epub_r] = ann_epub_r })
        local income_pdf = test_utils.write_mock_json(test_data_dir, "income_pdf.json", { [key_pdf_r] = ann_pdf_r })
        
        SyncService.sync = function(server, local_path, callback, upload_only)
            local income = local_path:match("juliet") and income_epub or income_pdf
            return callback(local_path, local_path, income)
        end

        -- 4. Sync All
        sync_instance.manager:syncAllChangedDocuments()

        -- 5. Verify EPUB (Active UI updated)
        assert.is_equal(2, #readerui.annotation.annotations)
        
        -- 6. Verify PDF (Sidecar updated)
        local ds_pdf_after = require("frontend/docsettings"):open(doc_pdf)
        local ann_pdf_after = ds_pdf_after:readSetting("annotations")
        assert.is_equal(2, #ann_pdf_after)
        
        assert.is_equal(0, (select(1, sync_instance.manager:getPendingChangedDocuments())))
    end)
end)
