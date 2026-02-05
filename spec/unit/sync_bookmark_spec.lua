describe("AnnotationSync Bookmark Synchronization", function()
    local ReaderUI, UIManager, SyncService, Geom, DataStorage
    local AnnotationSyncPlugin, test_utils, json, util, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_bookmark_tmp"
    local old_getDataDir
    local sample_epub = "spec/front/unit/data/juliet.epub"

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
        
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server"}))

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

    it("tracks dog-ear bookmarks and persists changed state", function()
        readerui.rolling:onGotoPage(5)
        fastforward_ui_events()
        
        -- Toggle bookmark
        readerui.bookmark:onToggleBookmark()
        
        assert.is_equal(1, #readerui.annotation.annotations)
        local bm = readerui.annotation.annotations[1]
        assert.truthy(bm.page)
        assert.falsy(bm.pos0) -- bookmarks don't have coordinates

        local count, docs = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(1, count)
        assert.is_true(docs[readerui.document.file])
    end)

    it("merges disjoint local and remote bookmarks", function()
        -- Local bookmark on page 5
        readerui.rolling:onGotoPage(5)
        fastforward_ui_events()
        readerui.bookmark:onToggleBookmark()
        local bm_l = readerui.annotation.annotations[1]
        bm_l.datetime = "2026-02-01 10:00:00"
        
        -- Remote bookmark on page 10
        local bm_r = {
            page = readerui.document:getPageXPointer(10),
            text = "Remote Bookmark",
            datetime = "2026-02-01 11:00:00"
        }
        local key_r = annotations_mod.annotation_key(bm_r)
        
        local income_path = test_utils.write_mock_json(test_data_dir, "income_bm.json", { [key_r] = bm_r })
        local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_bm.json", {})

        SyncService.sync = function(server, local_path, callback, upload_only)
            callback(local_path, last_sync_path, income_path)
        end

        sync_instance:manualSync()

        assert.is_equal(2, #readerui.annotation.annotations)
    end)

    it("identifies deleted bookmarks correctly (unit test)", function()
        local local_map = {
            ["BOOKMARK|page2"] = { page = "page2", text = "I am still here" }
        }
        local last_sync_map = {
            ["BOOKMARK|page1"] = { page = "page1", text = "I was deleted" },
            ["BOOKMARK|page2"] = { page = "page2", text = "I am still here" }
        }
        local mock_doc = {
            compareXPointers = function(this, a, b) 
                if a == b then return 0 end
                return a < b and 1 or -1
            end
        }

        annotations_mod.get_deleted_annotations(local_map, last_sync_map, mock_doc)

        assert.truthy(local_map["BOOKMARK|page1"], "Deleted bookmark should be added to local_map")
        assert.is_true(local_map["BOOKMARK|page1"].deleted, "Deleted bookmark should be marked deleted")
        assert.falsy(local_map["BOOKMARK|page2"].deleted, "Active bookmark should NOT be marked deleted")
    end)

    it("synchronizes bookmark deletions (with safety check bypassed)", function()
        -- 1. Create two bookmarks using XPointers and sync them
        local key1 = "BOOKMARK|/page1"
        local bm1 = { page = "/page1", text = "Bookmark 1", datetime = "2026-02-01 10:00:00" }
        
        local key2 = "BOOKMARK|/page2"
        local bm2 = { page = "/page2", text = "Bookmark 2", datetime = "2026-02-01 10:00:00" }
        
        -- Start with both in UI
        readerui.annotation.annotations = { bm1, bm2 }
        sync_instance:manualSync()
        
        -- 2. Delete one bookmark locally (bm1), keep bm2
        readerui.annotation.annotations = { bm2 }
        
        -- 3. Mock remote (still has both)
        local income_path = test_utils.write_mock_json(test_data_dir, "income_del_bm.json", { [key1] = bm1, [key2] = bm2 })
        local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_del_bm.json", { [key1] = bm1, [key2] = bm2 })

        local captured_json
        SyncService.sync = function(server, local_path, callback, upload_only)
            -- The callback updates local_path with merged data (including deletions)
            local success = callback(local_path, last_sync_path, income_path)
            
            local f = io.open(local_path, "r")
            captured_json = json.decode(f:read("*all"))
            f:close()
            
            return success
        end

        sync_instance:manualSync()
        
        -- Verify key1 was marked deleted and uploaded
        assert.truthy(captured_json[key1], "key1 should exist in sync json")
        assert.is_true(captured_json[key1].deleted, "key1 should be marked as deleted")
        
        -- Verify key2 is still there and NOT deleted
        assert.truthy(captured_json[key2])
        assert.falsy(captured_json[key2].deleted)
        
        -- Verify final state in UI is 1 bookmark (bm2)
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(bm2.page, readerui.annotation.annotations[1].page)
    end)

    it("accepts remote bookmark deletions", function()
        -- 1. Create a bookmark locally
        readerui.rolling:onGotoPage(5)
        fastforward_ui_events()
        readerui.bookmark:onToggleBookmark()
        local bm = readerui.annotation.annotations[1]
        local key = annotations_mod.annotation_key(bm)
        bm.datetime = "2026-02-01 10:00:00"
        
        -- 2. Mock remote DELETION (newer timestamp)
        local bm_del = util.tableDeepCopy(bm)
        bm_del.deleted = true
        bm_del.datetime_updated = "2026-02-01 11:00:00"
        
        local income_path = test_utils.write_mock_json(test_data_dir, "income_rem_del.json", { [key] = bm_del })
        local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_rem_del.json", { [key] = bm })

        SyncService.sync = function(server, local_path, callback, upload_only)
            return callback(local_path, last_sync_path, income_path)
        end

        sync_instance:manualSync()
        
        -- Verify final state is 0 bookmarks (deleted by remote)
        assert.is_equal(0, #readerui.annotation.annotations)
    end)

    it("synchronizes PDF bookmarks correctly", function()
        -- 1. Switch to PDF
        readerui:onClose()
        local sample_pdf = DataStorage:getDataDir() .. "/test_bm.pdf"
        require("ffi/util").copyFile("spec/front/unit/data/sample.pdf", sample_pdf)
        
        readerui, sync_instance = test_utils.init_integration_context(
            sample_pdf, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
        
        -- 2. Toggle bookmark on page 10
        readerui.paging:onGotoPage(10)
        fastforward_ui_events()
        readerui.bookmark:onToggleBookmark()
        
        assert.is_equal(1, #readerui.annotation.annotations)
        local bm_l = readerui.annotation.annotations[1]
        assert.is_equal(10, bm_l.page)
        
        local key_l = annotations_mod.annotation_key(bm_l)
        assert.is_equal("BOOKMARK|10", key_l)
        
        -- 3. Mock remote bookmark on page 20
        local bm_r = {
            page = 20,
            text = "Remote PDF Bookmark",
            datetime = "2026-02-01 11:00:00"
        }
        local key_r = annotations_mod.annotation_key(bm_r)
        
        local income_path = test_utils.write_mock_json(test_data_dir, "income_pdf_bm.json", { [key_r] = bm_r })
        local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_pdf_bm.json", {})

        SyncService.sync = function(server, local_path, callback, upload_only)
            return callback(local_path, last_sync_path, income_path)
        end

        sync_instance:manualSync()

        -- 4. Verify both are present
        assert.is_equal(2, #readerui.annotation.annotations)
    end)
end)
