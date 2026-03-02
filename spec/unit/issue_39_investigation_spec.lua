describe("Issue #39 Investigation: Unintended Deletion", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, highlight_db, test_utils, json, util, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_issue_39_tmp"
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
        
        local logger = require("logger")
        logger:setLevel(logger.levels.dbg)

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
        os.remove(sync_instance.manager:changedDocumentsFile())
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

    it("reproduces re-deletion if timestamps are identical (Hypothesis: latest-wins preference)", function()
        -- 1. Initial State: Sync an annotation
        local ann, key = create_ann_from_db(1, "Initial", "2026-01-01 12:00:00")
        table.insert(readerui.annotation.annotations, ann)
        
        SyncService.sync = function(server, local_path, callback)
            callback(local_path, local_path, local_path)
            return true
        end
        sync_instance:manualSync()

        -- 2. Remote Deletion (Newer timestamp)
        local ann_del = util.tableDeepCopy(ann)
        ann_del.deleted = true
        ann_del.datetime_updated = "2026-01-01 13:00:00"
        
        local income_path = test_utils.write_mock_json(test_data_dir, "income.json", { [key] = ann_del })
        local last_sync_path = test_utils.write_mock_json(test_data_dir, "last.json", { [key] = ann })

        SyncService.sync = function(server, local_path, callback)
            callback(local_path, last_sync_path, income_path)
            return true
        end
        sync_instance:manualSync()
        assert.is_equal(0, #readerui.annotation.annotations)

        -- 3. Restore locally
        -- NOTE: restoreAnnotation in main.lua DOES update datetime_updated to os.date()
        local deleted = sync_instance.manager:getDeletedAnnotations(readerui.document)
        sync_instance:restoreAnnotation(deleted[1], true)
        
        -- Let's MOCK the timestamp to be EXACTLY SAME as the remote deletion
        -- to see how the merge logic handles it.
        readerui.annotation.annotations[1].datetime_updated = "2026-01-01 13:00:00"
        readerui.annotation.annotations[1].datetime = "2026-01-01 13:00:00"

        -- 4. Sync again
        -- sync_callback will see:
        -- income_v: deleted=true, time=13:00
        -- local_v:  deleted=false (active), time=13:00
        
        -- M.is_before(income_v, local_v) will be false (since 13:00 < 13:00 is false)
        -- SO it will pick merged[income_k] = income_v (the DELETED one!)
        
        local sdr_dir = require("frontend/docsettings"):getSidecarDir(readerui.document.file)
        local filename = sync_instance.manager:_getAnnotationFilename(readerui.document.file)
        local local_path = sdr_dir .. "/" .. filename
        local sync_path = local_path .. ".sync"
        
        -- We manually call sync_callback to see the result
        local ok, merged_list = annotations_mod.sync_callback(readerui.document, local_path, sync_path, income_path, false)
        
        assert.is_true(ok)
        -- FAILURE EXPECTED HERE: if timestamps are identical, remote win (deletion)
        assert.is_equal(1, #merged_list, "Annotation should stay restored even if timestamps are identical")
    end)
end)
