describe("AnnotationSync PDF Core Integration", function()
    local ReaderUI, UIManager, SyncService, Geom, DataStorage
    local AnnotationSyncPlugin, highlight_pdf_db, test_utils, json, util, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_pdf_integration_tmp"
    local old_getDataDir
    local sample_pdf

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
        
        highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        sample_pdf = DataStorage:getDataDir() .. "/test.pdf"
        require("ffi/util").copyFile("spec/front/unit/data/sample.pdf", sample_pdf)

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))

        readerui, sync_instance = test_utils.init_integration_context(
            sample_pdf, AnnotationSyncPlugin
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
        sync_instance.settings.last_sync = "Never"
        sync_instance.settings.use_filename = true
        os.remove(sync_instance:changedDocumentsFile())
        
        test_utils.mock_sync_service(SyncService)
    end)

    local function create_pdf_ann_from_db(index, note, datetime)
        local entry = highlight_pdf_db[index]
        local ann = {
            page = entry.page_num,
            pos0 = util.tableDeepCopy(entry.pos0),
            pos1 = util.tableDeepCopy(entry.pos1),
            text = entry.text,
            chapter = "Test Chapter",
            datetime = datetime or "2026-01-01 12:00:00",
            note = note,
        }
        -- PDF positions need page and zoom for key generation and comparison
        ann.pos0.page = entry.page_num
        ann.pos1.page = entry.page_num
        ann.pos0.zoom = ann.pos0.zoom or 1
        ann.pos1.zoom = ann.pos1.zoom or 1
        
        return ann, annotations_mod.annotation_key(ann)
    end

    describe("Tracking & Persistence (PDF)", function()
        it("tracks PDF highlights and persists changed state", function()
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
            test_utils.emulate_highlight(readerui, highlight_pdf_db[1])

            local count, docs = sync_instance:getPendingChangedDocuments()
            assert.is_equal(1, count)
            assert.is_true(docs[readerui.document.file])

            sync_instance:manualSync()
            assert.is_false(sync_instance:hasPendingChangedDocuments())
        end)
    end)

    describe("Bidirectional Merge & Conflicts (PDF)", function()
        it("merges disjoint local and remote PDF additions", function()
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
            test_utils.emulate_highlight(readerui, highlight_pdf_db[1])
            
            local ann2, key2 = create_pdf_ann_from_db(2)
            local income_path = test_utils.write_mock_json(test_data_dir, "income_disjoint_pdf.json", { [key2] = ann2 })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_disjoint_pdf.json", {})

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()

            assert.is_equal(2, #readerui.annotation.annotations)
        end)

        it("merges overlapping PDF highlights (latest wins)", function()
            -- Local has a highlight
            local entry = highlight_pdf_db[1]
            test_utils.emulate_highlight(readerui, entry)
            local local_ann = readerui.annotation.annotations[1]
            local_ann.datetime = "2026-02-01 10:00:00"
            local_ann.note = "Local Version"
            
            -- Remote has an OVERLAPPING highlight (same page, slightly different coordinates)
            -- We'll manually construct it to ensure it overlaps
            local remote_ann = util.tableDeepCopy(local_ann)
            remote_ann.pos1.x = remote_ann.pos1.x + 10 -- Slightly longer
            remote_ann.datetime = "2026-02-01 11:00:00" -- Newer
            remote_ann.note = "Remote Newer Version"
            
            local key_r = annotations_mod.annotation_key(remote_ann)
            local income_path = test_utils.write_mock_json(test_data_dir, "income_overlap_pdf.json", { [key_r] = remote_ann })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_overlap_pdf.json", {})

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()

            -- Should have 1 highlight (merged) and it should be the remote one (newer)
            assert.is_equal(1, #readerui.annotation.annotations)
            assert.is_equal("Remote Newer Version", readerui.annotation.annotations[1].note)
        end)

        it("handles slight coordinate drift (drift tolerance)", function()
            -- Local has a highlight
            local entry = highlight_pdf_db[1]
            test_utils.emulate_highlight(readerui, entry)
            local local_ann = readerui.annotation.annotations[1]
            local_ann.datetime = "2026-02-01 10:00:00"
            local_ann.note = "Local Original"
            
            -- Remote has the same highlight but with slight coordinate drift (e.g. 0.5 units)
            local remote_ann = util.tableDeepCopy(local_ann)
            remote_ann.pos0.x = remote_ann.pos0.x + 0.5
            remote_ann.pos1.x = remote_ann.pos1.x - 0.5
            remote_ann.datetime = "2026-02-01 11:00:00" -- Newer
            remote_ann.note = "Drifted Version"
            
            local key_l = annotations_mod.annotation_key(local_ann)
            local key_r = annotations_mod.annotation_key(remote_ann)
            
            local income_path = test_utils.write_mock_json(test_data_dir, "income_drift_pdf.json", { [key_r] = remote_ann })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_drift_pdf.json", {})

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()

            -- Should still merge because they intersect significantly
            assert.is_equal(1, #readerui.annotation.annotations)
            assert.is_equal("Drifted Version", readerui.annotation.annotations[1].note)
        end)

        it("resolves PDF conflicts using timestamps (latest wins)", function()
            local ann_l, key = create_pdf_ann_from_db(1, "Local Newer PDF", "2026-02-02 12:00:00")
            table.insert(readerui.annotation.annotations, ann_l)
            
            local ann_r, _ = create_pdf_ann_from_db(1, "Remote Older PDF", "2026-02-01 12:00:00")
            local income_path = test_utils.write_mock_json(test_data_dir, "income_conflict_pdf.json", { [key] = ann_r })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_conflict_pdf.json", { [key] = ann_r })

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()
            assert.is_equal("Local Newer PDF", readerui.annotation.annotations[1].note)
        end)
    end)

    describe("Deletion (PDF)", function()
        it("synchronizes PDF deletions bidirectionally", function()
            local ann, key = create_pdf_ann_from_db(1)
            table.insert(readerui.annotation.annotations, ann)
            
            local ann_del = util.tableDeepCopy(ann)
            ann_del.deleted = true
            ann_del.datetime_updated = "2026-02-02 12:00:00"
            
            local income_path = test_utils.write_mock_json(test_data_dir, "income_del_pdf.json", { [key] = ann_del })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_del_pdf.json", { [key] = ann })

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()
            assert.is_equal(0, #readerui.annotation.annotations)
        end)
    end)
end)
