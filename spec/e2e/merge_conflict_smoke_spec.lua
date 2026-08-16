-- E2E: Clean-merge + timestamp-conflict smoke checks over a real local
-- WebDAV server.
--
-- Re-runs the two bidirectional-merge cases already proven at the unit
-- level (spec/unit/sync_integration_spec.lua, against a mocked
-- SyncService) as a real-network smoke check: does the real WebDAV round
-- trip preserve disjoint-merge and latest-wins-conflict behavior? Not a
-- re-proof of the merge algorithm itself (annotation_sweep.lua already
-- has unit coverage for that).
--
-- A second annotation set is seeded directly onto the real WebDAV server
-- (bypassing a second device) to stand in for "another device already
-- synced this". Sync itself is still driven by firing the real
-- `AnnotationSyncManualSync` KOReader Event at a live ReaderUI, the same
-- seam ticket 04 established.
--
-- Requires: ./run_e2e_tests.sh <koreader_root>, which starts the local
-- webdav-cli server this spec talks to. Not wired into run_tests.sh/CI.
describe("AnnotationSync E2E merge/conflict smoke", function()
    local Event, UIManager, util
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, annotations_mod, changed_documents

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
        os.remove(changed_documents.path())

        return readerui, sync_instance, old_getDataDir, old_ImageViewer_new
    end

    local function teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end

    local function run_clean_merge(test_data_dir, file, entry_local, entry_remote, before_highlight)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        test_utils.emulate_highlight(readerui, entry_local)
        test_utils.emulate_highlight(readerui, entry_remote)
        assert.is_equal(2, #readerui.annotation.annotations)

        local local_text = readerui.annotation.annotations[1].text
        local remote_ann = util.tableDeepCopy(readerui.annotation.annotations[2])
        local remote_text = remote_ann.text
        local remote_key = annotations_mod.annotation_key(remote_ann)

        -- Forget the remote-side addition locally: only the local
        -- addition remains, so the next sync must pull the other one
        -- back from the real WebDAV server to merge them.
        table.remove(readerui.annotation.annotations, 2)
        assert.is_equal(1, #readerui.annotation.annotations)

        local seed_code = e2e_test_utils.seed_remote_annotations(
            sync_instance, file, { [remote_key] = remote_ann }, test_data_dir
        )
        assert.is_true(seed_code >= 200 and seed_code < 300)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(2, #readerui.annotation.annotations)
        local texts = {}
        for _, ann in ipairs(readerui.annotation.annotations) do
            texts[ann.text] = true
        end
        assert.is_true(texts[local_text])
        assert.is_true(texts[remote_text])

        teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
    end

    local function run_timestamp_conflict(test_data_dir, file, entry, before_highlight)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)

        local local_ann = readerui.annotation.annotations[1]
        local local_text = local_ann.text
        local key = annotations_mod.annotation_key(local_ann)

        local remote_ann = util.tableDeepCopy(local_ann)
        remote_ann.text = "Remote Older Edit"
        remote_ann.datetime = "2000-01-01 00:00:00"

        local seed_code = e2e_test_utils.seed_remote_annotations(
            sync_instance, file, { [key] = remote_ann }, test_data_dir
        )
        assert.is_true(seed_code >= 200 and seed_code < 300)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(local_text, readerui.annotation.annotations[1].text)

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
        changed_documents = require("changed_documents")
        annotations_mod = require("annotations")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("merges disjoint local and remote EPUB additions over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_clean_merge_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        -- Distinct basename from other e2e spec files: `use_filename` makes
        -- the remote annotation filename derive from this, and meson runs
        -- spec files in parallel against the same shared WebDAV server.
        local file = fresh_copy(test_data_dir, "clean_merge.epub", "spec/front/unit/data/juliet.epub")

        run_clean_merge(test_data_dir, file, highlight_db[1], highlight_db[2], function(readerui)
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
        end)
    end)

    it("merges disjoint local and remote PDF additions over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_clean_merge_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "clean_merge.pdf", "spec/front/unit/data/sample.pdf")

        run_clean_merge(test_data_dir, file, highlight_pdf_db[1], highlight_pdf_db[2], function(readerui)
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
        end)
    end)

    it("resolves an EPUB timestamp conflict in favor of the local edit over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_timestamp_conflict_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "timestamp_conflict.epub", "spec/front/unit/data/juliet.epub")

        run_timestamp_conflict(test_data_dir, file, highlight_db[1], function(readerui)
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
        end)
    end)

    it("resolves a PDF timestamp conflict in favor of the local edit over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_timestamp_conflict_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "timestamp_conflict.pdf", "spec/front/unit/data/sample.pdf")

        run_timestamp_conflict(test_data_dir, file, highlight_pdf_db[1], function(readerui)
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
        end)
    end)
end)
