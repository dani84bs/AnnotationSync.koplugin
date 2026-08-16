describe("AnnotationSync Sync Protection & Regressions", function()
    local ReaderUI, UIManager, Geom, SyncService
    local AnnotationSyncPlugin, highlight_db, test_utils, json, changed_documents
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
        changed_documents = require("changed_documents")

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
        changed_documents.add(readerui.document.file)
        
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
        sync_instance.manager:syncAllChangedDocuments()
        
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
        
        -- 1. Mock the dependency
        local old_ds_module = package.loaded["frontend/docsettings"]
        package.loaded["frontend/docsettings"] = mock_ds
        
        -- 2. Load Manager directly (bypassing Plugin/Main)
        -- We must force a reload of manager to pick up the new docsettings mock
        local old_manager = package.loaded["manager"]
        package.loaded["manager"] = nil
        local SyncManager = require("manager")
        
        -- 3. Instantiate Manager with a dummy plugin interface
        local mock_plugin = { ui = readerui, settings = {} }
        local manager_instance = SyncManager:new(mock_plugin)

        -- 4. Verify
        local result = manager_instance:getAnnotationsForDocument({ file = "any.epub" })
        assert.is_equal(1, #result)
        assert.is_equal("test_page", result[1].page)

        -- 5. Cleanup
        package.loaded["frontend/docsettings"] = old_ds_module
        package.loaded["manager"] = old_manager
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

    it("keeps a wide local annotation available across multiple matching uploaded entries (Issue 69 pointer regression)", function()
        -- Regression guard for the O(n^2) fix in get_deleted_annotations: a single
        -- wide-ranging local annotation spans two uploaded annotations. The
        -- persistent scan pointer must NOT be advanced past it after the first
        -- match, or the second uploaded annotation would be wrongly marked deleted.
        local annotations_mod = require("annotations")
        local local_map = {
            ["005||005"] = { pos0 = "005", pos1 = "005", page = "005", text = "early, non-overlapping" },
            ["010||050"] = { pos0 = "010", pos1 = "050", page = "010", text = "wide, overlaps both uploaded entries" },
        }
        local last_sync_map = {
            ["020||020"] = { pos0 = "020", pos1 = "020", page = "020", text = "u1, inside the wide range" },
            ["040||040"] = { pos0 = "040", pos1 = "040", page = "040", text = "u2, also inside the wide range" },
        }
        local mock_doc = {
            compareXPointers = function(self, a, b)
                if a == b then return 0 end
                return a < b and 1 or -1
            end
        }

        annotations_mod.get_deleted_annotations(local_map, last_sync_map, mock_doc)

        assert.falsy(last_sync_map["020||020"].deleted, "u1 should still be matched by the wide local annotation")
        assert.falsy(last_sync_map["040||040"].deleted, "u2 should still be matched by the wide local annotation")
    end)

    it("does not skip a still-relevant later local annotation when an earlier one is discarded (Issue 69 pointer regression)", function()
        -- Regression guard: local[1] is discarded (ends before u1 starts), advancing
        -- the persistent pointer to local[2]. local[2] does not intersect u1 either
        -- (so u1 is correctly marked deleted), but it MUST remain available and
        -- correctly match u2 afterwards -- proving the pointer isn't consumed by a
        -- non-matching comparison.
        local annotations_mod = require("annotations")
        local local_map = {
            ["005||005"] = { pos0 = "005", pos1 = "005", page = "005", text = "ends before u1" },
            ["030||045"] = { pos0 = "030", pos1 = "045", page = "030", text = "starts after u1, overlaps u2" },
        }
        local last_sync_map = {
            ["020||020"] = { pos0 = "020", pos1 = "020", page = "020", text = "u1, unmatched by any local annotation" },
            ["040||040"] = { pos0 = "040", pos1 = "040", page = "040", text = "u2, matched by local[030||045]" },
        }
        local mock_doc = {
            compareXPointers = function(self, a, b)
                if a == b then return 0 end
                return a < b and 1 or -1
            end
        }

        annotations_mod.get_deleted_annotations(local_map, last_sync_map, mock_doc)

        assert.is_true(local_map["020||020"].deleted, "u1 should be marked deleted (no local annotation overlaps it)")
        assert.falsy(last_sync_map["040||040"].deleted, "u2 should still be matched by local[030||045]")
    end)

    it("should allow deletions if local map is empty but 'force' is true (Manual Override)", function()
        local annotations_mod = require("annotations")
        local local_map = {} -- EMPTY
        local last_sync_map = {
            ["p1|p2"] = { pos0 = "p1", pos1 = "p2", text = "Gone?" }
        }
        local mock_doc = {
            compareXPointers = function() return 0 end
        }

        -- This SHOULD mark as deleted because force is true
        annotations_mod.get_deleted_annotations(local_map, last_sync_map, mock_doc, true)

        local list = annotations_mod.map_to_list(local_map)
        assert.is_equal(0, #list) -- map_to_list filters out .deleted = true
        assert.is_not_nil(local_map["p1|p2"])
        assert.is_true(local_map["p1|p2"].deleted)
    end)
end)
