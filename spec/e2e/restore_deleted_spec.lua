-- E2E: restore-deleted-annotation round trip over a real local WebDAV
-- server.
--
-- Deletes a highlight locally, syncs (pushing the tombstone find_deleted
-- writes into the local sync JSON and the real remote map), restores it via
-- the same manager:getDeletedAnnotations/plugin:restoreAnnotation path the
-- "Show Deleted" menu (menus.lua) drives, syncs again, and confirms it
-- reappears live on the real remote -- not just the in-process tombstone
-- logic already unit-tested (spec/unit/sync_trash_spec.lua).
describe("AnnotationSync E2E restore-deleted-annotation scenario", function()
    local Event, UIManager
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, annotations_key

    local function fresh_copy(test_data_dir, name, source)
        local dest = test_data_dir .. "/" .. name
        require("ffi/util").copyFile(source, dest)
        return dest
    end

    local function boot(test_data_dir, file)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)
        local old_ImageViewer_new = test_utils.mock_image_viewer()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
        sync_instance.settings.last_sync = "Never"
        sync_instance.settings.use_filename = true
        os.remove(require("changed_documents").path())

        return readerui, sync_instance, old_getDataDir, old_ImageViewer_new
    end

    local function teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end

    local function run_restore_deleted_scenario(test_data_dir, file, entry, before_highlight)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)
        local key = annotations_key(readerui.annotation.annotations[1])

        -- Establish a baseline synced state before the delete, so the
        -- second sync below is a real tombstone-push round-trip rather
        -- than a first-ever upload.
        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Mirrors what the real "Delete" highlight menu action does:
        -- ReaderHighlight:deleteHighlight removes the entry from
        -- readerui.annotation.annotations directly.
        readerui.highlight:deleteHighlight(1)
        assert.is_equal(0, #readerui.annotation.annotations)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(0, #readerui.annotation.annotations)

        local remote_map_after_delete, delete_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(delete_code ~= nil and delete_code >= 200 and delete_code < 300)
        assert.is_not_nil(remote_map_after_delete)
        assert.is_not_nil(remote_map_after_delete[key])
        assert.is_true(remote_map_after_delete[key].deleted)

        -- Real "Show Deleted" menu path: menus.lua reads the tombstoned
        -- entries via manager:getDeletedAnnotations, then restores the
        -- chosen one via plugin:restoreAnnotation -- the same calls this
        -- spec drives directly, without the widget itself.
        local deleted = sync_instance.manager:getDeletedAnnotations(readerui.document)
        assert.is_equal(1, #deleted)
        assert.is_equal(key, annotations_key(deleted[1]))

        -- Non-silent, matching the real per-item "Restore" menu callback
        -- (menus.lua's ok_callback: plugin:restoreAnnotation(ann)).
        sync_instance:restoreAnnotation(deleted[1])
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_false(readerui.annotation.annotations[1].deleted)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(key, annotations_key(readerui.annotation.annotations[1]))

        local remote_map_after_restore, restore_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(restore_code ~= nil and restore_code >= 200 and restore_code < 300)
        assert.is_not_nil(remote_map_after_restore)
        assert.is_not_nil(remote_map_after_restore[key])
        assert.is_falsy(remote_map_after_restore[key].deleted)

        teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        UIManager = require("ui/uimanager")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        annotations_key = require("annotations").annotation_key
    end)

    it("restores a deleted EPUB highlight and syncs over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_restore_deleted_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "restore_deleted.epub", "spec/front/unit/data/juliet.epub")

        run_restore_deleted_scenario(test_data_dir, file, highlight_db[1], function(readerui)
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
        end)
    end)

    it("restores a deleted PDF highlight and syncs over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_restore_deleted_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "restore_deleted.pdf", "spec/front/unit/data/sample.pdf")

        run_restore_deleted_scenario(test_data_dir, file, highlight_pdf_db[1], function(readerui)
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
        end)
    end)
end)
