-- E2E: network-auto-reconnect wiring over a real local WebDAV server.
--
-- Proves AnnotationSyncPlugin:_onNetworkConnected's real event wiring --
-- with "Automatically Sync All when network becomes available" enabled and
-- a pending local change present, firing KOReader's real `NetworkConnected`
-- event (not a direct SyncAll/manualSync call) triggers a Sync All that
-- lands the change on the real WebDAV server, with no manual sync action
-- taken. The sync logic itself is already covered by
-- manual_sync_lifecycle_spec.lua/sync_all_happy_path_spec.lua.
describe("AnnotationSync E2E network auto-reconnect", function()
    local Event, UIManager, changed_documents
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
        changed_documents = require("changed_documents")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        annotations_key = require("annotations").annotation_key
    end)

    it("syncs a pending EPUB change when NetworkConnected fires", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_network_auto_reconnect_epub_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file = fresh_copy(test_data_dir, "test.epub", "spec/front/unit/data/juliet.epub")

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

        sync_instance.settings.network_auto_sync = true
        sync_instance:registerEvents()

        readerui.rolling:onGotoPage(3)
        fastforward_ui_events()
        test_utils.emulate_highlight(readerui, highlight_db[1])
        assert.is_equal(1, #readerui.annotation.annotations)
        local uploaded_key = annotations_key(readerui.annotation.annotations[1])

        assert.is_true(changed_documents.has_pending())

        readerui:handleEvent(Event:new("NetworkConnected"))
        -- _onNetworkConnected schedules the actual sync via
        -- UIManager:scheduleIn, so it needs its own tick beyond the one
        -- that runs it.
        fastforward_ui_events()
        fastforward_ui_events()

        assert.is_false(changed_documents.has_pending())

        local remote_annotations, code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, file, test_data_dir)
        assert.is_true(code ~= nil and code >= 200 and code < 300)
        assert.is_not_nil(remote_annotations)
        assert.is_not_nil(remote_annotations[uploaded_key])

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end)
end)
