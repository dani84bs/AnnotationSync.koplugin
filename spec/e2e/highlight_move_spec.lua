-- E2E: highlight move-semantics scenario over a real local WebDAV server.
--
-- Moving a highlight changes its position -- and therefore its
-- position-derived key from annotation_key(). There is no dedicated
-- move-merge path in annotation_sweep.lua today, so this pins down
-- today's actual behavior: a move round-trips as the old key being
-- tombstoned (find_deleted marks the uploaded entry `deleted = true`
-- rather than removing it) and the new key being added alongside it --
-- both locally and on the remote.
describe("AnnotationSync E2E move-semantics scenario", function()
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

    local function run_move_scenario(
        test_data_dir, file, entry, second_entry, before_highlight, before_second_highlight
    )
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Establish a baseline synced state before the move, so the
        -- second sync below is a real merge round-trip rather than a
        -- first-ever upload.
        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)

        local old_key = annotations_key(readerui.annotation.annotations[1])

        if before_second_highlight then
            before_second_highlight(readerui)
        end

        -- Highlight a second, distinct position purely to obtain a
        -- document-valid pos0/pos1(/page) to move the original highlight
        -- to, then discard it -- the scenario wants one moved
        -- annotation, not two.
        test_utils.emulate_highlight(readerui, second_entry)
        assert.is_equal(2, #readerui.annotation.annotations)
        local scratch = readerui.annotation.annotations[2]
        local new_pos0, new_pos1, new_page = scratch.pos0, scratch.pos1, scratch.page
        readerui.highlight:deleteHighlight(2)
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Mirrors what an in-place highlight move would leave behind:
        -- same annotation table, new position fields, then the same
        -- AnnotationsModified Event a real edit fires.
        local item = readerui.annotation.annotations[1]
        item.pos0 = new_pos0
        item.pos1 = new_pos1
        item.page = new_page
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

        -- Current behavior: no dedicated move-merge path exists, so the
        -- old key isn't removed from the remote map -- find_deleted
        -- tombstones it (`deleted = true`) instead -- while the new key
        -- is added as a live entry alongside it.
        assert.is_not_nil(remote_map[old_key])
        assert.is_true(remote_map[old_key].deleted)
        assert.is_not_nil(remote_map[new_key])
        assert.is_falsy(remote_map[new_key].deleted)
        assert.is_equal(2, count_keys(remote_map))

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

    it("moves an EPUB highlight to a new position and syncs over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_move_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "move.epub", "spec/front/unit/data/juliet.epub")

        run_move_scenario(
            test_data_dir, file, highlight_db[1], highlight_db[52],
            function(readerui)
                readerui.rolling:onGotoPage(3)
                fastforward_ui_events()
            end,
            function(readerui)
                readerui.rolling:onGotoPage(5)
                fastforward_ui_events()
            end
        )
    end)

    it("moves a PDF highlight to a new position and syncs over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_move_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "move.pdf", "spec/front/unit/data/sample.pdf")

        run_move_scenario(
            test_data_dir, file, highlight_pdf_db[1], highlight_pdf_db[87],
            function(readerui)
                readerui.paging:onGotoPage(10)
                fastforward_ui_events()
            end
        )
    end)
end)
