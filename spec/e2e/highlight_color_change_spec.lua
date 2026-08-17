-- E2E: highlight color/style-change tripwire over a real local WebDAV
-- server.
--
-- Research for this ticket found no `color`/`drawer`/`style` field anywhere
-- in the sync/merge code (annotations.lua, annotation_sweep.lua) -- these
-- fields are neither read nor stripped, they just ride along inside the
-- annotation table like any other field. This spec doesn't assert what
-- *should* happen; it pins down what *does* happen today, so a future
-- change to color-sync support shows up as a reviewed test update instead
-- of a silent behavior change.
describe("AnnotationSync E2E highlight color-change scenario", function()
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

    -- Mirrors what ReaderHighlight:editHighlightStyle/editHighlightColor's
    -- ButtonSelector callback does on selection, minus the widget itself:
    -- mutate the fields, then fire the same AnnotationsModified Event so
    -- datetime_updated (and any sync tracking hooked to it) advances the
    -- same way a real user edit would.
    local function change_highlight_style(readerui, index, drawer, color)
        local item = readerui.annotation.annotations[index]
        item.drawer = drawer
        item.color = color
        readerui:handleEvent(Event:new("AnnotationsModified", { item }))
    end

    local function run_color_change_scenario(test_data_dir, file, entry, before_highlight)
        local readerui, sync_instance, old_getDataDir, old_ImageViewer_new = boot(test_data_dir, file)

        if before_highlight then
            before_highlight(readerui)
        end

        test_utils.emulate_highlight(readerui, entry)
        assert.is_equal(1, #readerui.annotation.annotations)

        -- Establish a baseline synced state before the color/style edit,
        -- so the second sync below is a real merge round-trip rather than
        -- a first-ever upload.
        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))
        assert.is_equal(1, #readerui.annotation.annotations)

        change_highlight_style(readerui, 1, "underscore", "blue")
        assert.is_equal("underscore", readerui.annotation.annotations[1].drawer)
        assert.is_equal("blue", readerui.annotation.annotations[1].color)

        readerui:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui.annotation.annotations)
        local synced = readerui.annotation.annotations[1]

        -- Current behavior: the color/style change survives the local
        -- round-trip because sync/merge operates on whole annotation
        -- tables and doesn't touch these fields at all.
        assert.is_equal("underscore", synced.drawer)
        assert.is_equal("blue", synced.color)

        local key = annotations_key(synced)
        local remote_map, code = e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(code ~= nil and code >= 200 and code < 300)
        assert.is_not_nil(remote_map)
        local remote_entry = remote_map[key]
        assert.is_not_nil(remote_entry)

        -- Current behavior: the changed color/style is also uploaded to
        -- the real WebDAV server as part of the merged, re-uploaded state.
        assert.is_equal("underscore", remote_entry.drawer)
        assert.is_equal("blue", remote_entry.color)

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

    it("changes an EPUB highlight's color/style locally and syncs over real WebDAV", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_color_change_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "color_change.epub", "spec/front/unit/data/juliet.epub")

        run_color_change_scenario(test_data_dir, file, highlight_db[1], function(readerui)
            readerui.rolling:onGotoPage(3)
            fastforward_ui_events()
        end)
    end)

    it("changes a PDF highlight's color/style locally and syncs over real WebDAV", function()
        local highlight_pdf_db = require("spec/unit/highlight_pdf_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_color_change_pdf_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "color_change.pdf", "spec/front/unit/data/sample.pdf")

        run_color_change_scenario(test_data_dir, file, highlight_pdf_db[1], function(readerui)
            readerui.paging:onGotoPage(10)
            fastforward_ui_events()
        end)
    end)
end)
