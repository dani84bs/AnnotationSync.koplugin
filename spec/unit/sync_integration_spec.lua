describe("AnnotationSync Core Integration", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, highlight_db, test_utils, json, util, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_integration_tmp"
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
        
        highlight_db = require("spec/unit/highlight_db")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))

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
        sync_instance.settings.last_sync = "Never"
        sync_instance.settings.use_filename = true
        os.remove(sync_instance:changedDocumentsFile())
        
        test_utils.mock_sync_service(SyncService)
    end)

    local function create_ann_from_db(index, note, datetime)
        local entry = highlight_db[index]
        local ann = {
            page = entry.p0,
            pos0 = entry.p0,
            pos1 = entry.p1,
            text = entry.text,
            chapter = "Test Chapter",
            datetime = datetime or "2026-01-01 12:00:00",
            note = note,
        }
        return ann, annotations_mod.annotation_key(ann)
    end

    describe("Tracking & Persistence", function()
        it("tracks highlights and persists changed state", function()
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
            test_utils.emulate_highlight(readerui, highlight_db[1])

            local count, docs = sync_instance:getPendingChangedDocuments()
            assert.is_equal(1, count)
            assert.is_true(docs[readerui.document.file])

            sync_instance:manualSync()
            assert.is_false(sync_instance:hasPendingChangedDocuments())
        end)
    end)

    describe("Bidirectional Merge & Conflicts", function()
        it("merges disjoint local and remote additions", function()
            test_utils.emulate_highlight(readerui, highlight_db[1])
            
            local ann2, key2 = create_ann_from_db(2)
            local income_path = test_utils.write_mock_json(test_data_dir, "income_disjoint.json", { [key2] = ann2 })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_disjoint.json", {})

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()

            assert.is_equal(2, #readerui.annotation.annotations)
        end)

        it("resolves conflicts using timestamps (latest wins)", function()
            local ann_l, key = create_ann_from_db(1, "Local Newer", "2026-02-02 12:00:00")
            table.insert(readerui.annotation.annotations, ann_l)
            
            local ann_r, _ = create_ann_from_db(1, "Remote Older", "2026-02-01 12:00:00")
            local income_path = test_utils.write_mock_json(test_data_dir, "income_conflict.json", { [key] = ann_r })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_conflict.json", { [key] = ann_r })

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()
            assert.is_equal("Local Newer", readerui.annotation.annotations[1].note)
        end)

        it("resurrects zombie if modification is newer than deletion", function()
            -- Remote has deletion, but local has a NEWER modification
            local ann_l, key = create_ann_from_db(1, "Revived", "2026-02-05 12:00:00")
            table.insert(readerui.annotation.annotations, ann_l)

            local ann_r, _ = create_ann_from_db(1)
            ann_r.deleted = true
            ann_r.datetime_updated = "2026-02-01 12:00:00"

            local income_path = test_utils.write_mock_json(test_data_dir, "income_zombie.json", { [key] = ann_r })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_zombie.json", { [key] = ann_r })

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()
            assert.is_equal(1, #readerui.annotation.annotations)
            assert.is_equal("Revived", readerui.annotation.annotations[1].note)
        end)
    end)

    describe("Deletion", function()
        it("synchronizes deletions bidirectionally", function()
            local ann, key = create_ann_from_db(1)
            table.insert(readerui.annotation.annotations, ann)
            
            local ann_del = util.tableDeepCopy(ann)
            ann_del.deleted = true
            ann_del.datetime_updated = "2026-02-02 12:00:00"
            
            local income_path = test_utils.write_mock_json(test_data_dir, "income_del.json", { [key] = ann_del })
            local last_sync_path = test_utils.write_mock_json(test_data_dir, "last_del.json", { [key] = ann })

            SyncService.sync = function(server, local_path, callback, upload_only)
                callback(local_path, last_sync_path, income_path)
            end

            sync_instance:manualSync()
            assert.is_equal(0, #readerui.annotation.annotations)
        end)
    end)
end)
