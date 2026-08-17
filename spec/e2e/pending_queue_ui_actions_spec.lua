-- E2E: Pending Documents Queue menu actions over a real local WebDAV
-- server.
--
-- The queue menu (menus.lua:296-374) has two per-document actions with no
-- prior e2e coverage: "Sync now" and "Remove from list" -- distinct from
-- sync_all_happy_path_spec.lua's bulk AnnotationSyncSyncAll event. Drives
-- both through the real menus.show_pending_documents(plugin) entry point,
-- mocking Menu.new/ConfirmBox.new only to capture the real callbacks
-- (same technique spec/unit/unsynced_documents_spec.lua and
-- restore_deleted_spec.lua's menu path use), not to replace any logic.
--
-- Mixed EPUB+PDF batch, matching the map's bulk/multi-document convention:
-- the EPUB is the live ReaderUI document ("Sync now" target, exercising
-- the in-memory sync path); the PDF is sidecar-seeded and never opened
-- ("Remove from list" target, exercising the untouched-inactive-doc path,
-- mirroring sync_all_happy_path_spec.lua's active/inactive split).
describe("AnnotationSync E2E pending queue UI actions", function()
    local Event, UIManager, docsettings, changed_documents, Menu, ConfirmBox
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, menus, annotations_key, highlight_db, highlight_pdf_db

    local function fresh_copy(test_data_dir, name, source)
        local dest = test_data_dir .. "/" .. name
        require("ffi/util").copyFile(source, dest)
        return dest
    end

    -- Mirrors sync_all_happy_path_spec.lua's inactive-document seeding: a
    -- local annotation written directly to the docsettings sidecar, as if
    -- a live ReaderUI on another occasion had produced it.
    local function seed_inactive_document(file, entry)
        local ds = docsettings:open(file)
        ds:saveSetting("annotations", {
            {
                pos0 = entry.p0,
                pos1 = entry.p1,
                text = entry.text,
                datetime = "2026-02-01 10:00:00",
                note = "",
            },
        })
        ds:flush()
        changed_documents.add(file)
    end

    -- Captures the real Menu/ConfirmBox constructor args instead of
    -- painting a widget, so the callbacks menus.lua wires up can be
    -- invoked directly, as if tapped.
    local function capture_pending_menu()
        local menu_items
        Menu.new = function(_, o)
            menu_items = o.item_table
            return { onShow = function() end, paintTo = function() end, free = function() end, handleEvent = function() end }
        end
        return function() return menu_items end
    end

    local function capture_confirm_box()
        local confirm_opts
        ConfirmBox.new = function(_, o)
            confirm_opts = o
            return { onShow = function() end, paintTo = function() end, free = function() end, handleEvent = function() end }
        end
        return function() return confirm_opts end
    end

    local function find_item(menu_items, clean_filename)
        for _, item in ipairs(menu_items) do
            if item.text == clean_filename then return item end
        end
        error("no pending-queue menu item for " .. clean_filename)
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
        Menu = require("ui/widget/menu")
        ConfirmBox = require("ui/widget/confirmbox")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        menus = require("menus")
        annotations_key = require("annotations").annotation_key
        highlight_db = require("spec/unit/highlight_db")
        highlight_pdf_db = require("spec/unit/highlight_pdf_db")
    end)

    it("syncs one queued document and removes another through the real menu", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_pending_queue_tmp"
        os.execute("mkdir -p " .. test_data_dir)

        local active_file = fresh_copy(test_data_dir, "queue_sync.epub", "spec/front/unit/data/juliet.epub")
        local inactive_file = fresh_copy(test_data_dir, "queue_remove.pdf", "spec/front/unit/data/sample.pdf")

        local old_getDataDir = test_utils.setup_test_env(test_data_dir)
        local old_ImageViewer_new = test_utils.mock_image_viewer()
        local old_Menu_new = Menu.new
        local old_ConfirmBox_new = ConfirmBox.new

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

        seed_inactive_document(inactive_file, highlight_pdf_db[1])

        assert.is_equal(2, (changed_documents.get_pending()))

        local get_menu_items = capture_pending_menu()
        menus.show_pending_documents(sync_instance)
        local menu_items = get_menu_items()
        assert.is_equal(2, #menu_items)

        -- "Sync now" on the EPUB (live ReaderUI document): tap opens the
        -- real ConfirmBox, ok_callback drives the real syncDocument path.
        local get_confirm_opts = capture_confirm_box()
        find_item(menu_items, "queue_sync.epub").callback()
        local confirm_opts = get_confirm_opts()
        assert.is_not_nil(confirm_opts.ok_callback)

        local get_menu_items_after_sync = capture_pending_menu()
        confirm_opts.ok_callback()
        fastforward_ui_events()

        assert.is_equal(1, (changed_documents.get_pending()))
        assert.is_equal(1, #readerui.annotation.annotations)
        assert.is_equal(active_key, annotations_key(readerui.annotation.annotations[1]))

        local remote_active, active_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, active_file, test_data_dir)
        assert.is_true(active_code ~= nil and active_code >= 200 and active_code < 300)
        assert.is_not_nil(remote_active)
        assert.is_not_nil(remote_active[active_key])

        -- syncDocument's completion callback re-invokes
        -- menus.show_pending_documents(plugin) itself to refresh the list
        -- -- the capture above observes that real reopen, not a re-call
        -- this spec makes.
        local menu_items_after_sync = get_menu_items_after_sync()
        assert.is_equal(1, #menu_items_after_sync)
        assert.is_equal("queue_remove.pdf", menu_items_after_sync[1].text)

        -- "Remove from list" on the PDF (never opened by this test): tap
        -- opens the real ConfirmBox, other_buttons callback drives the
        -- real changed_documents.remove_by_path path, with no sync.
        local get_confirm_opts_2 = capture_confirm_box()
        menu_items_after_sync[1].callback()
        local confirm_opts_2 = get_confirm_opts_2()
        assert.is_not_nil(confirm_opts_2.other_buttons)

        confirm_opts_2.other_buttons[1][1].callback()

        assert.is_false(changed_documents.has_pending())

        local remote_inactive, inactive_code =
            e2e_test_utils.fetch_remote_annotations(sync_instance, inactive_file, test_data_dir)
        assert.is_true(remote_inactive == nil or inactive_code == nil or inactive_code == 404)

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        Menu.new = old_Menu_new
        ConfirmBox.new = old_ConfirmBox_new
        UIManager:quit()
        package.loaded["main"] = nil
        package.loaded["menus"] = nil
    end)
end)
