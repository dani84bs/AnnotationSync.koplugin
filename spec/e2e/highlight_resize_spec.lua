-- E2E: highlight resize-semantics scenario over a real local WebDAV server.
--
-- Resizing a highlight changes its pos1 (enlarge extends it, shrink
-- retracts it) while pos0 -- and therefore the highlight's start -- stays
-- put. That overlapping range hits the range-overlap fallback in
-- positions_intersect(): the old and new positions share a start, so they
-- are treated as the same annotation despite their different
-- annotation_key(), and the merge keeps only the resized entry -- no
-- tombstone, unlike a move to an unrelated position.
describe("AnnotationSync E2E resize-semantics scenario", function()
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

    local function count_keys(map)
        local n = 0
        for _ in pairs(map) do n = n + 1 end
        return n
    end

    local function run_resize_scenario(
        test_data_dir, file, entry, resized_entry, before_highlight
    )
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        -- Highlight the resized range first, purely to obtain a
        -- document-valid pos1 sharing the original's pos0, then discard
        -- it -- doing this before the real highlight exists avoids
        -- KOReader's overlapping-highlight edit path, which would kick in
        -- if this range were drawn on top of the already-present original.
        test_utils.emulate_highlight(readerui, resized_entry)
        assert.is_equal(1, #readerui.annotation.annotations)
        local new_pos1 = readerui.annotation.annotations[1].pos1
        readerui.highlight:deleteHighlight(1)
        assert.is_equal(0, #readerui.annotation.annotations)

        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Establish a baseline synced state before the resize, so the
        -- second sync below is a real merge round-trip rather than a
        -- first-ever upload.
        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)

        local old_key = annotations_key(readerui.annotation.annotations[1])

        -- Mirrors what an in-place resize would leave behind: same
        -- annotation table, same pos0, new pos1, then the same
        -- AnnotationsModified Event a real edit fires.
        local item = readerui.annotation.annotations[1]
        item.pos1 = new_pos1
        readerui:handleEvent(Event:new("AnnotationsModified", { item }))

        local new_key = annotations_key(item)
        assert.is_not_equal(old_key, new_key)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui.annotation.annotations)
        local synced = readerui.annotation.annotations[1]
        assert.is_equal(new_key, annotations_key(synced))

        local remote_map, code = e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(code ~= nil and code >= 200 and code < 300)
        assert.is_not_nil(remote_map)

        -- Current behavior: pos0 is unchanged, so positions_intersect's
        -- range-overlap fallback matches the old and new positions as the
        -- same annotation -- unlike a move, the old key is never
        -- tombstoned, it simply stops existing.
        assert.is_nil(remote_map[old_key])
        assert.is_not_nil(remote_map[new_key])
        assert.is_falsy(remote_map[new_key].deleted)
        assert.is_equal(1, count_keys(remote_map))

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

    it("enlarges an EPUB highlight and syncs over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_resize_enlarge_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "resize_enlarge.epub", "spec/front/unit/data/juliet.epub")

        run_resize_scenario(
            test_data_dir, file,
            highlight_db[1],
            { pos0 = highlight_db[1].pos0, pos1 = highlight_db[3].pos1 },
            function(readerui)
                readerui.rolling:onGotoPage(3)
                fastforward_ui_events()
            end
        )
    end)

    it("shrinks an EPUB highlight and syncs over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_resize_shrink_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "resize_shrink.epub", "spec/front/unit/data/juliet.epub")

        run_resize_scenario(
            test_data_dir, file,
            { pos0 = highlight_db[1].pos0, pos1 = highlight_db[3].pos1 },
            { pos0 = highlight_db[1].pos0, pos1 = highlight_db[1].pos1 },
            function(readerui)
                readerui.rolling:onGotoPage(3)
                fastforward_ui_events()
            end
        )
    end)

    it("enlarges a PDF highlight and syncs over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_resize_enlarge_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "resize_enlarge.pdf", "spec/front/unit/data/sample.pdf")

        run_resize_scenario(
            test_data_dir, file,
            highlight_pdf_db[1],
            { pos0 = highlight_pdf_db[1].pos0, pos1 = highlight_pdf_db[3].pos1 },
            function(readerui)
                readerui.paging:onGotoPage(10)
                fastforward_ui_events()
            end
        )
    end)

    it("shrinks a PDF highlight and syncs over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_resize_shrink_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "resize_shrink.pdf", "spec/front/unit/data/sample.pdf")

        run_resize_scenario(
            test_data_dir, file,
            { pos0 = highlight_pdf_db[1].pos0, pos1 = highlight_pdf_db[3].pos1 },
            { pos0 = highlight_pdf_db[1].pos0, pos1 = highlight_pdf_db[1].pos1 },
            function(readerui)
                readerui.paging:onGotoPage(10)
                fastforward_ui_events()
            end
        )
    end)
end)
