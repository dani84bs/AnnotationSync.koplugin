-- E2E: Sync All happy-path over a real local WebDAV server.
--
-- Distinct from manual_sync_lifecycle_spec.lua's single-document path: one
-- device tracks two EPUB documents, each with a pending local annotation
-- change, and a single real `AnnotationSyncSyncAll` KOReader Event syncs
-- both against the real remote in one shot.
--
-- The second document is represented purely via its docsettings sidecar
-- (no second live ReaderUI) -- syncAllChangedDocuments/getDocumentByFile
-- opens, syncs, and closes it transiently itself, exactly as production
-- code does for any tracked-but-inactive document.
--
-- Requires: ./run_e2e_tests.sh <koreader_root>, which starts the local
-- webdav-cli server this spec talks to. Not wired into run_tests.sh/CI.
describe("AnnotationSync E2E Sync All happy path", function()
    local Event, UIManager, docsettings, changed_documents
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, annotations_key, highlight_db

    local function fresh_copy(test_data_dir, name, source)
        local dest = test_data_dir .. "/" .. name
        require("ffi/util").copyFile(source, dest)
        return dest
    end

    -- Seeds a local annotation directly into `file`'s docsettings sidecar
    -- and marks it pending -- mirrors what a live ReaderUI highlight +
    -- AnnotationsModified event would have produced, without a second
    -- ReaderUI instance.
    local function seed_inactive_document(file, entry)
        local ds = docsettings:open(file)
        local ann = {
            pos0 = entry.p0,
            pos1 = entry.p1,
            text = entry.text,
            datetime = "2026-02-01 10:00:00",
            note = "",
        }
        ds:saveSetting("annotations", { ann })
        ds:flush()
        changed_documents.add(file)
        return ann
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        UIManager = require("ui/uimanager")
        docsettings = require("docsettings")
        changed_documents = require("changed_documents")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        annotations_key = require("annotations").annotation_key
        highlight_db = require("spec/unit/highlight_db")
    end)

    it("syncs two pending EPUB documents with a single Sync All event", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_sync_all_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)

        -- Distinct basenames: `use_filename` derives the remote annotation
        -- filename from these, and meson runs e2e spec files in parallel
        -- against the same shared WebDAV server.
        local active_file = fresh_copy(test_data_dir, "sync_all_active.epub", "spec/front/unit/data/juliet.epub")
        local inactive_file = fresh_copy(test_data_dir, "sync_all_inactive.epub", "spec/front/unit/data/juliet.epub")

        local old_getDataDir = test_utils.setup_test_env(test_data_dir)
        local old_ImageViewer_new = test_utils.mock_image_viewer()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            active_file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
        sync_instance.settings.last_sync = "Never"
        sync_instance.settings.use_filename = true
        os.remove(changed_documents.path())

        readerui.rolling:onGotoPage(3)
        fastforward_ui_events()
        test_utils.emulate_highlight(readerui, highlight_db[1])
        assert.is_equal(1, #readerui.annotation.annotations)
        local active_key = annotations_key(readerui.annotation.annotations[1])

        local inactive_ann = seed_inactive_document(inactive_file, highlight_db[2])
        local inactive_key = annotations_key(inactive_ann)

        assert.is_equal(2, (changed_documents.get_pending()))

        readerui:handleEvent(Event:new("AnnotationSyncSyncAll"))

        assert.is_false(changed_documents.has_pending())

        -- Active document: still live in memory, untouched by the
        -- transient open/close cycle syncAllChangedDocuments uses for the
        -- inactive document.
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(active_key, annotations_key(readerui.annotation.annotations[1]))

        -- Inactive document: re-read from its sidecar, since it was only
        -- ever opened transiently by Sync All itself.
        local ds_after = docsettings:open(inactive_file)
        local annotations_after = ds_after:readSetting("annotations")
        assert.is_equal(1, #annotations_after)
        assert.is_equal(inactive_key, annotations_key(annotations_after[1]))

        local remote_active, active_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, active_file, test_data_dir)
        assert.is_true(active_code ~= nil and active_code >= 200 and active_code < 300)
        assert.is_not_nil(remote_active)
        assert.is_not_nil(remote_active[active_key])

        local remote_inactive, inactive_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, inactive_file, test_data_dir)
        assert.is_true(inactive_code ~= nil and inactive_code >= 200 and inactive_code < 300)
        assert.is_not_nil(remote_inactive)
        assert.is_not_nil(remote_inactive[inactive_key])

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
