-- E2E: fresh-device pulldown of pre-existing remote annotations, over a
-- real local WebDAV server.
--
-- Two scenarios, both distinct from the other e2e specs:
--
-- 1. A genuinely new device (its own test_data_dir, its own sdr, no local
--    annotations, no .sync sidecar) opening a same-named file for the
--    first time must pull down annotations a *different* device already
--    uploaded under that remote filename.
-- 2. The Issue-23 empty-local-map deletion guard (unit-tested directly in
--    spec/unit/sync_protection_spec.lua) must also hold end-to-end: when
--    in-memory annotations are lost but the .sync sidecar survives, a
--    non-manual resync (force=false, the real Sync All / auto-sync path --
--    manual sync always forces past the guard) must not propagate the
--    loss to the remote, and the annotation must reappear locally.
describe("AnnotationSync E2E fresh-device existing-remote scenario", function()
    local Event, UIManager, docsettings, changed_documents
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

    local function sync_json_path(sync_instance, file)
        local sdr_dir = docsettings:getSidecarDir(file)
        local filename = sync_instance.manager:_getAnnotationFilename(file)
        return sdr_dir .. "/" .. filename
    end

    -- Phase 1: two sequential single-process devices, same remote filename.
    local function run_fresh_device_pulldown(basename, source, entry, before_highlight)
        local dir_a = os.getenv("PWD") .. "/test_e2e_fresh_device_a_tmp_" .. basename:gsub("%.", "_")
        os.execute("mkdir -p " .. dir_a)
        local file_a = fresh_copy(dir_a, basename, source)

        local readerui_a, sync_instance_a, old_getDataDir_a, old_ImageViewer_a = boot(dir_a, file_a)
        before_highlight(readerui_a)
        test_utils.emulate_highlight(readerui_a, entry)
        assert.is_equal(1, #readerui_a.annotation.annotations)
        local uploaded_key = annotations_key(readerui_a.annotation.annotations[1])

        readerui_a:handleEvent(Event:new("AnnotationSyncManualSync"))

        local remote_after_upload, upload_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance_a, file_a, dir_a)
        assert.is_true(upload_code ~= nil and upload_code >= 200 and upload_code < 300)
        assert.is_not_nil(remote_after_upload)
        assert.is_not_nil(remote_after_upload[uploaded_key])

        teardown(dir_a, readerui_a, old_getDataDir_a, old_ImageViewer_a)

        -- Device B: same basename (so the same remote filename), a
        -- completely separate test_data_dir/sdr -- no local annotations,
        -- no .sync sidecar, nothing carried over from device A.
        local dir_b = os.getenv("PWD") .. "/test_e2e_fresh_device_b_tmp_" .. basename:gsub("%.", "_")
        os.execute("mkdir -p " .. dir_b)
        local file_b = fresh_copy(dir_b, basename, source)

        local readerui_b, sync_instance_b, old_getDataDir_b, old_ImageViewer_b = boot(dir_b, file_b)
        assert.is_equal(0, #readerui_b.annotation.annotations)

        readerui_b:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui_b.annotation.annotations)
        assert.is_equal(uploaded_key, annotations_key(readerui_b.annotation.annotations[1]))

        teardown(dir_b, readerui_b, old_getDataDir_b, old_ImageViewer_b)
    end

    -- Phase 2: single boot, in-memory annotations cleared but the .sync
    -- sidecar left untouched -- the actual guard-protection case.
    local function run_local_map_guard_scenario(basename, source, entry, before_highlight)
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_local_map_guard_tmp_" .. basename:gsub("%.", "_")
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, basename, source)

        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)
        before_highlight(readerui)
        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)
        local uploaded_key = annotations_key(readerui.annotation.annotations[1])

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_true(require("util").fileExists(sync_json_path(sync_instance, file) .. ".sync"))

        -- Simulate in-memory annotation loss (e.g. a crash/reload) without
        -- touching the .sync sidecar -- the local map goes empty while the
        -- last-known-synced map on disk stays non-empty.
        readerui.annotation.annotations = {}
        changed_documents.add(readerui.document.file)

        -- Sync All drives syncDocument with is_manual=false, so the
        -- Issue-23 guard actually runs (manual sync always forces past
        -- it, per SyncManager:syncDocument's is_manual/force wiring).
        readerui:handleEvent(Event:new("AnnotationSyncSyncAll"))

        assert.is_false(changed_documents.has_pending())
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(uploaded_key, annotations_key(readerui.annotation.annotations[1]))

        local remote_after_resync, resync_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(resync_code ~= nil and resync_code >= 200 and resync_code < 300)
        assert.is_not_nil(remote_after_resync)
        assert.is_not_nil(remote_after_resync[uploaded_key])
        assert.is_falsy(remote_after_resync[uploaded_key].deleted)

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
        docsettings = require("docsettings")
        changed_documents = require("changed_documents")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        annotations_key = require("annotations").annotation_key
    end)

    it("pulls down an EPUB highlight onto a fresh device", function()
        local highlight_db = require("spec/unit/highlight_db")
        run_fresh_device_pulldown("fresh_device.epub", "spec/front/unit/data/juliet.epub", highlight_db[1],
            function(readerui)
                readerui.rolling:onGotoPage(3)
                fastforward_ui_events()
            end)
    end)

    it("pulls down a PDF highlight onto a fresh device", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        run_fresh_device_pulldown("fresh_device.pdf", "spec/front/unit/data/sample.pdf", highlight_pdf_db[1],
            function(readerui)
                readerui.paging:onGotoPage(10)
                fastforward_ui_events()
            end)
    end)

    it("protects an EPUB highlight when the local map goes empty but .sync survives", function()
        local highlight_db = require("spec/unit/highlight_db")
        run_local_map_guard_scenario("local_map_guard.epub", "spec/front/unit/data/juliet.epub", highlight_db[1],
            function(readerui)
                readerui.rolling:onGotoPage(3)
                fastforward_ui_events()
            end)
    end)

    it("protects a PDF highlight when the local map goes empty but .sync survives", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        run_local_map_guard_scenario("local_map_guard.pdf", "spec/front/unit/data/sample.pdf", highlight_pdf_db[1],
            function(readerui)
                readerui.paging:onGotoPage(10)
                fastforward_ui_events()
            end)
    end)
end)
