-- E2E: clean-merge, timestamp-conflict, and delete-then-restore checks for
-- BOOKMARK|-keyed entries over a real local WebDAV server.
--
-- Mirrors merge_conflict_smoke_spec.lua and restore_deleted_spec.lua, which
-- already cover this ground for highlight (pos0/pos1-keyed) annotations --
-- this spec gives dog-ear bookmarks the same real-network coverage.
describe("AnnotationSync E2E bookmark merge/conflict/restore", function()
    local Event, UIManager, util
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, annotations_mod

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

    -- Toggles a dog-ear bookmark onto `page`: the same
    -- ReaderBookmark:onToggleBookmark path Shift-Right / the dog-ear tap
    -- drives, adding an entry to readerui.annotation.annotations.
    local function add_bookmark(readerui, page)
        if readerui.rolling then
            readerui.rolling:onGotoPage(page)
        else
            readerui.paging:onGotoPage(page)
        end
        fastforward_ui_events()
        readerui.bookmark:onToggleBookmark()
        return readerui.annotation.annotations[#readerui.annotation.annotations]
    end

    local function run_clean_merge(test_data_dir, file, local_page, remote_page)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        add_bookmark(readerui, local_page)
        add_bookmark(readerui, remote_page)
        assert.is_equal(2, #readerui.annotation.annotations)

        local local_bm = util.tableDeepCopy(readerui.annotation.annotations[1])
        local local_text = local_bm.text
        local local_key = annotations_mod.annotation_key(local_bm)
        local remote_bm = util.tableDeepCopy(readerui.annotation.annotations[2])
        local remote_text = remote_bm.text
        local remote_key = annotations_mod.annotation_key(remote_bm)

        -- Forget the remote-side addition locally: only the local addition
        -- remains, so the next sync must pull the other one back from the
        -- real WebDAV server to merge them.
        table.remove(readerui.annotation.annotations, 2)
        assert.is_equal(1, #readerui.annotation.annotations)

        local seed_code = e2e_test_utils.seed_remote_annotations(
            sync_instance, file, { [remote_key] = remote_bm }, test_data_dir
        )
        assert.is_true(seed_code >= 200 and seed_code < 300)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(2, #readerui.annotation.annotations)
        local by_key = {}
        for _, bm in ipairs(readerui.annotation.annotations) do
            by_key[annotations_mod.annotation_key(bm)] = bm
        end

        local merged_local = by_key[local_key]
        local merged_remote = by_key[remote_key]
        assert.is_not_nil(merged_local)
        assert.is_not_nil(merged_remote)
        assert.is_equal(local_text, merged_local.text)
        assert.is_equal(remote_text, merged_remote.text)
        assert.is_falsy(merged_local.deleted)
        assert.is_falsy(merged_remote.deleted)

        teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
    end

    local function run_timestamp_conflict(test_data_dir, file, page)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        add_bookmark(readerui, page)
        assert.is_equal(1, #readerui.annotation.annotations)

        local local_bm = readerui.annotation.annotations[1]
        local local_text = local_bm.text
        local local_datetime = local_bm.datetime
        local key = annotations_mod.annotation_key(local_bm)

        local remote_bm = util.tableDeepCopy(local_bm)
        remote_bm.text = "Remote Older Edit"
        remote_bm.datetime = "2000-01-01 00:00:00"

        local seed_code = e2e_test_utils.seed_remote_annotations(
            sync_instance, file, { [key] = remote_bm }, test_data_dir
        )
        assert.is_true(seed_code >= 200 and seed_code < 300)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui.annotation.annotations)
        local merged = readerui.annotation.annotations[1]
        assert.is_equal(key, annotations_mod.annotation_key(merged))
        assert.is_equal(local_text, merged.text)
        assert.is_equal(local_datetime, merged.datetime)
        assert.is_falsy(merged.deleted)

        teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
    end

    local function run_restore_deleted(test_data_dir, file, page)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        add_bookmark(readerui, page)
        assert.is_equal(1, #readerui.annotation.annotations)
        local key = annotations_mod.annotation_key(readerui.annotation.annotations[1])

        -- Establish a baseline synced state before the delete, so the
        -- second sync below is a real tombstone-push round-trip rather
        -- than a first-ever upload.
        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Mirrors the real dog-ear toggle: there's no separate "delete"
        -- action for a bookmark, toggling the already-bookmarked page again
        -- removes it from readerui.annotation.annotations directly.
        readerui.bookmark:onToggleBookmark()
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
        assert.is_equal(key, annotations_mod.annotation_key(deleted[1]))

        sync_instance:restoreAnnotation(deleted[1])
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_false(readerui.annotation.annotations[1].deleted)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(key, annotations_mod.annotation_key(readerui.annotation.annotations[1]))

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
        util = require("util")
        annotations_mod = require("annotations")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("merges disjoint local and remote EPUB bookmarks over real WebDAV", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_bookmark_clean_merge_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "clean_merge_bm.epub", "spec/front/unit/data/juliet.epub")

        run_clean_merge(test_data_dir, file, 5, 10)
    end)

    it("merges disjoint local and remote PDF bookmarks over real WebDAV", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_bookmark_clean_merge_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "clean_merge_bm.pdf", "spec/front/unit/data/sample.pdf")

        run_clean_merge(test_data_dir, file, 10, 20)
    end)

    it("resolves an EPUB bookmark timestamp conflict in favor of the local edit over real WebDAV", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_bookmark_timestamp_conflict_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "timestamp_conflict_bm.epub", "spec/front/unit/data/juliet.epub")

        run_timestamp_conflict(test_data_dir, file, 5)
    end)

    it("resolves a PDF bookmark timestamp conflict in favor of the local edit over real WebDAV", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_bookmark_timestamp_conflict_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "timestamp_conflict_bm.pdf", "spec/front/unit/data/sample.pdf")

        run_timestamp_conflict(test_data_dir, file, 10)
    end)

    it("restores a deleted EPUB bookmark and syncs over real WebDAV", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_bookmark_restore_deleted_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "restore_deleted_bm.epub", "spec/front/unit/data/juliet.epub")

        run_restore_deleted(test_data_dir, file, 5)
    end)

    it("restores a deleted PDF bookmark and syncs over real WebDAV", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_bookmark_restore_deleted_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "restore_deleted_bm.pdf", "spec/front/unit/data/sample.pdf")

        run_restore_deleted(test_data_dir, file, 10)
    end)
end)
