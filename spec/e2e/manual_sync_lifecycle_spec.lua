-- E2E: Manual Sync lifecycle over a real local WebDAV server.
--
-- Fires the real `AnnotationSyncManualSync` KOReader Event at a live
-- ReaderUI -- the same dispatch path a gesture, menu tap, or
-- `Dispatcher:execute()` takes -- and asserts a highlight round-trips
-- correctly through a real WebDAV server (started by run_e2e_tests.sh).
describe("AnnotationSync E2E Manual Sync lifecycle", function()
    local Event, ReaderUI, UIManager, Geom, DataStorage, docsettings
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, json, changed_documents

    local function fresh_copy(test_data_dir, name, source)
        local dest = test_data_dir .. "/" .. name
        require("ffi/util").copyFile(source, dest)
        return dest
    end

    local function sync_json_path(sync_instance, file)
        local sdr_dir = docsettings:getSidecarDir(file)
        local filename = sync_instance.manager:_getAnnotationFilename(file)
        return sdr_dir .. "/" .. filename
    end

    -- Simulates the local device having no memory of any prior sync (e.g. a
    -- fresh install), while leaving the remote WebDAV state untouched --
    -- forcing the next sync to actually pull from the real server rather
    -- than replaying local state.
    local function forget_local_sync_state(readerui, sync_instance, file)
        readerui.annotation.annotations = {}
        os.remove(sync_json_path(sync_instance, file) .. ".sync")
    end

    local function run_lifecycle(test_data_dir, file, highlight_entry, before_highlight)
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

        if before_highlight then
            before_highlight(readerui)
        end
        test_utils.emulate_highlight(readerui, highlight_entry)
        assert.is_equal(1, #readerui.annotation.annotations)
        local uploaded_note = readerui.annotation.annotations[1].text

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_false(changed_documents.has_pending())
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(uploaded_note, readerui.annotation.annotations[1].text)

        forget_local_sync_state(readerui, sync_instance, file)
        assert.is_equal(0, #readerui.annotation.annotations)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(uploaded_note, readerui.annotation.annotations[1].text)

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        DataStorage = require("datastorage")
        docsettings = require("docsettings")
        json = require("json")
        changed_documents = require("changed_documents")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("round-trips an EPUB highlight through a real WebDAV server", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_manual_sync_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "test.epub", "spec/front/unit/data/juliet.epub")

        run_lifecycle(test_data_dir, file, highlight_db[1], function(readerui)
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
        end)
    end)

    it("round-trips a PDF highlight through a real WebDAV server", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_manual_sync_pdf_tmp"

        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "test.pdf", "spec/front/unit/data/sample.pdf")

        run_lifecycle(test_data_dir, file, highlight_pdf_db[1], function(readerui)
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
        end)
    end)
end)
