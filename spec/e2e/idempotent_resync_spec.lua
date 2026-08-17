-- E2E: idempotent resync over a real local WebDAV server.
--
-- Proves that syncing twice with no changes in between is a no-op: the
-- second sync must not mutate local annotations, remote annotations, or
-- introduce any tombstone -- distinct from restore_deleted_spec.lua, which
-- exercises a real tombstone push/restore round-trip.
describe("AnnotationSync E2E idempotent resync scenario", function()
    local Event, UIManager, util
    local AnnotationSyncPlugin, test_utils, e2e_test_utils

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

    local function has_any_tombstone(annotations)
        for _, ann in pairs(annotations) do
            if ann.deleted then
                return true
            end
        end
        return false
    end

    local function run_idempotent_resync_scenario(test_data_dir, file, entry, before_highlight)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Snapshots taken right after sync #1.
        local local_snapshot = util.tableDeepCopy(readerui.annotation.annotations)
        local remote_snapshot, snapshot_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(snapshot_code ~= nil and snapshot_code >= 200 and snapshot_code < 300)
        assert.is_not_nil(remote_snapshot)
        assert.is_false(has_any_tombstone(remote_snapshot))

        -- Sync #2, with no intervening local or remote changes.
        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.same(local_snapshot, readerui.annotation.annotations)

        local remote_after, after_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(after_code ~= nil and after_code >= 200 and after_code < 300)
        assert.is_not_nil(remote_after)
        assert.same(remote_snapshot, remote_after)
        assert.is_false(has_any_tombstone(remote_after))

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

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("resyncs an EPUB with no changes without mutating state", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_idempotent_resync_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "idempotent_resync.epub", "spec/front/unit/data/juliet.epub")

        run_idempotent_resync_scenario(test_data_dir, file, highlight_db[1], function(readerui)
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
        end)
    end)

    it("resyncs a PDF with no changes without mutating state", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_idempotent_resync_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "idempotent_resync.pdf", "spec/front/unit/data/sample.pdf")

        run_idempotent_resync_scenario(test_data_dir, file, highlight_pdf_db[1], function(readerui)
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
        end)
    end)
end)
