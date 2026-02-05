describe("AnnotationSync Trash & Restore", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, highlight_db, test_utils, json, annotations_mod
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_trash_tmp"
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
        annotations_mod = require("annotations")
        
        highlight_db = require("spec/unit/highlight_db")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        G_reader_settings:saveSetting("cloud_download_dir", "mock")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="mock"}))

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

    it("should correctly identify deleted annotations in the sync JSON", function()
        -- 1. Setup a sync JSON with one deleted item
        local file = readerui.document.file
        local sdr_dir = require("frontend/docsettings"):getSidecarDir(file)
        
        -- Ensure directory exists (recursive)
        os.execute("mkdir -p " .. sdr_dir)

        sync_instance.settings.use_filename = false -- use hash
        local filename = sync_instance.manager:_getAnnotationFilename(file)
        local json_path = sdr_dir .. "/" .. filename

        local mock_data = {
            ["p1||p2"] = { page = 1, pos0 = "p1", pos1 = "p2", text = "Active" },
            ["d1||d2"] = { page = 2, pos0 = "d1", pos1 = "d2", text = "Deleted", deleted = true }
        }
        
        local f = io.open(json_path, "w")
        if not f then error("Could not open " .. json_path) end
        f:write(json.encode(mock_data))
        f:close()

        -- 2. Check getDeletedAnnotations
        local deleted = sync_instance.manager:getDeletedAnnotations(readerui.document)
        assert.is_equal(1, #deleted)
        assert.is_equal("Deleted", deleted[1].text)
        assert.is_true(deleted[1].deleted)
    end)

    it("should restore a deleted annotation and notify the system", function()
        readerui.annotation.annotations = {
            { page = 1, pos0 = "p1", pos1 = "p2", text = "Existing" }
        }
        
        local trash_item = { 
            page = 2, 
            pos0 = "d1", 
            pos1 = "d2", 
            text = "Restored", 
            deleted = true,
            datetime_updated = "old"
        }

        -- Mock event broadcast tracking
        local event_received = false
        local old_event_new = require("ui/event").new
        require("ui/event").new = function(self_ev, name, ...)
            if name == "AnnotationsModified" then
                event_received = true
            end
            return old_event_new(self_ev, name, ...)
        end

        -- 1. Restore
        sync_instance:restoreAnnotation(trash_item)

        -- 2. Verify
        assert.is_false(trash_item.deleted)
        assert.is_not_equal("old", trash_item.datetime_updated)
        assert.is_equal(2, #readerui.annotation.annotations)
        assert.is_true(event_received)

        -- Cleanup
        require("ui/event").new = old_event_new
    end)
end)
