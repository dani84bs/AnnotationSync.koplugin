-- E2E: "Sync All (including unread)" over a real local WebDAV server.
--
-- Proves the gh-89 scan-and-sync path end-to-end: a book that was never
-- opened through this plugin (no changed_documents entry, seeded purely
-- via its docsettings sidecar, exactly as a book read before the plugin
-- was installed would look) gets discovered by the library scan, marked
-- dirty, and actually pushed to a real remote by the existing Sync All
-- machinery -- not just asserted against a mocked SyncService.
--
-- The real Trapper:dismissableRunInSubprocess subprocess round trip needs
-- genuine wall-clock time fastforward_ui_events() can't inject
-- deterministically (see progress_sync_throttle_spec.lua), so Trapper is
-- run inline/synchronously here, same as the unit-level spec. What this
-- test adds over the unit-level spec is a REAL SyncService push against
-- the WebDAV server.
describe("AnnotationSync E2E Sync All (including unread)", function()
    local Event, UIManager, Trapper, docsettings, changed_documents
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, annotations_key

    local function fresh_copy(test_data_dir, name, source)
        local dest = test_data_dir .. "/" .. name
        require("ffi/util").copyFile(source, dest)
        return dest
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        UIManager = require("ui/uimanager")
        Trapper = require("ui/trapper")
        docsettings = require("docsettings")
        changed_documents = require("changed_documents")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        annotations_key = require("annotations").annotation_key
    end)

    it("discovers a never-synced book on disk and pushes its annotations for real", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_library_full_sync_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local library_dir = test_data_dir .. "/library"
        os.execute("mkdir -p " .. library_dir)

        -- The active document lives outside the scanned library dir, so
        -- the scan's only find is the never-synced book below.
        local active_file = fresh_copy(test_data_dir, "active.epub", "spec/front/unit/data/juliet.epub")
        local unsynced_file = fresh_copy(library_dir, "unsynced.epub", "spec/front/unit/data/juliet.epub")

        local old_getDataDir = test_utils.setup_test_env(test_data_dir)
        local old_ImageViewer_new = test_utils.mock_image_viewer()
        local old_home_dir = G_reader_settings:readSetting("home_dir")
        G_reader_settings:saveSetting("home_dir", library_dir)

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            active_file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
        sync_instance.settings.use_filename = true
        os.remove(changed_documents.path())

        -- Seed the never-synced book directly on its sidecar, mirroring a
        -- highlight made before this plugin was ever installed: no
        -- changed_documents entry, nothing but local annotation state.
        local ds = docsettings:open(unsynced_file)
        local ann = {
            pos0 = "/body/DocFragment[8]/body/p[3]/text().0",
            pos1 = "/body/DocFragment[8]/body/p[3]/text().20",
            text = "gh-89 pre-existing highlight",
            datetime = "2026-02-01 10:00:00",
            note = "",
        }
        ds:saveSetting("annotations", { ann })
        ds:flush()
        local expected_key = annotations_key(ann)

        assert.is_equal(0, (changed_documents.get_pending()))

        Trapper.wrap = function(this, func) func() end
        Trapper.dismissableRunInSubprocess = function(this, func, trap_widget_or_string)
            return true, func()
        end

        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = ConfirmBox.new
        ConfirmBox.new = function(this, o)
            if o.ok_callback then o.ok_callback() end
            return { onShow = function() end, paintTo = function() end, free = function() end, handleEvent = function() end }
        end

        sync_instance.manager:scanAndSyncAllBooks()
        fastforward_ui_events()

        ConfirmBox.new = old_ConfirmBox_new

        assert.is_false(changed_documents.has_pending())

        local remote_data, code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, unsynced_file, test_data_dir)
        assert.is_true(code ~= nil and code >= 200 and code < 300)
        assert.is_not_nil(remote_data)
        assert.is_not_nil(remote_data[expected_key])

        readerui:onClose()
        G_reader_settings:saveSetting("home_dir", old_home_dir)
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
