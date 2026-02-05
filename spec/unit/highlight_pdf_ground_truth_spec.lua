describe("AnnotationSync PDF Highlight Ground Truth Integration", function()
    local ReaderUI, UIManager, Geom, DataStorage
    local AnnotationSyncPlugin, highlight_pdf_db, test_utils
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_sync_pdf_ground_truth_tmp"
    local old_getDataDir
    local sample_pdf

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        DataStorage = require("datastorage")
        
        highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        _G.old_ImageViewer_new = test_utils.mock_image_viewer()

        sample_pdf = DataStorage:getDataDir() .. "/test.pdf"
        require("ffi/util").copyFile("spec/front/unit/data/sample.pdf", sample_pdf)

        readerui, sync_instance = test_utils.init_integration_context(
            sample_pdf, AnnotationSyncPlugin
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
        os.remove(sync_instance.manager:changedDocumentsFile())
    end)

    it("should generate highlights for selected PDF ground truth entries and track them", function()
        -- Select a few entries from the PDF ground truth
        local test_entries = {
            highlight_pdf_db[1],  -- "dwindle away"
            highlight_pdf_db[7],  -- "a graceful"
            highlight_pdf_db[13], -- "hearing of his great reputation..."
        }

        for _, entry in ipairs(test_entries) do
            readerui.paging:onGotoPage(entry.page_num)
            fastforward_ui_events()

            test_utils.emulate_highlight(readerui, entry)
        end
        
        assert.is_equal(#test_entries, #readerui.annotation.annotations)

        for i, entry in ipairs(test_entries) do
            local stored_ann = readerui.annotation.annotations[i]
            -- PDF text might have some encoding/whitespace differences, but should match closely
            assert.is_equal(entry.text, stored_ann.text)
        end
        
        local count, changed_docs = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(1, count)
        assert.is_true(changed_docs[readerui.document.file])
    end)
end)
