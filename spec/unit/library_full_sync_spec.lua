describe("Sync All (including unread) full library sync (gh-89)", function()
    local ReaderUI, UIManager, SyncService, Geom, Trapper, G_settings
    local AnnotationSyncPlugin, test_utils, json, util, changed_documents, docsettings
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_library_full_sync_tmp"
    local library_dir = test_data_dir .. "/library"
    local fixture_epub = os.getenv("PWD") .. "/test/juliet.epub"
    local old_getDataDir
    local old_home_dir

    local function make_book(relative_path)
        local dest = library_dir .. "/" .. relative_path
        local dir = dest:match("(.*)/")
        if dir then os.execute("mkdir -p " .. dir) end
        os.execute("cp " .. fixture_epub .. " " .. dest)
        return dest
    end

    local function give_annotations(file, annotations)
        local sidecar = docsettings:open(file)
        sidecar:saveSetting("annotations", annotations)
        sidecar:flush()
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        Trapper = require("ui/trapper")
        json = require("json")
        util = require("util")
        docsettings = require("frontend/docsettings")

        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")
        changed_documents = require("changed_documents")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        os.execute("mkdir -p " .. test_data_dir .. "/plugins")

        G_reader_settings:saveSetting("cloud_download_dir", "http://mock-server")
        G_reader_settings:saveSetting("cloud_server_object", json.encode({url="http://mock-server", type="webdav"}))

        readerui, sync_instance = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
        package.loaded["menus"] = nil
    end)

    before_each(function()
        os.remove(changed_documents.path())
        os.execute("rm -rf " .. library_dir)
        os.execute("mkdir -p " .. library_dir)

        old_home_dir = G_reader_settings:readSetting("home_dir")
        G_reader_settings:saveSetting("home_dir", library_dir)

        -- Run scans/subprocesses inline and synchronously for tests.
        Trapper.wrap = function(this, func) func() end
        Trapper.dismissableRunInSubprocess = function(this, func, trap_widget_or_string)
            return true, func()
        end
    end)

    after_each(function()
        G_reader_settings:saveSetting("home_dir", old_home_dir)
        os.execute("rm -rf " .. library_dir)
    end)

    local function auto_confirm()
        local ConfirmBox = require("ui/widget/confirmbox")
        local old_new = ConfirmBox.new
        ConfirmBox.new = function(this, o)
            if o.ok_callback then o.ok_callback() end
            return { onShow = function() end, paintTo = function() end, free = function() end, handleEvent = function() end }
        end
        return old_new
    end

    it("marks discovered unsynced books dirty and triggers Sync All", function()
        local book = make_book("book1.epub")
        give_annotations(book, {{ page = 1, text = "hi" }})

        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = auto_confirm()

        local sync_all_called = false
        local pending_at_call = 0
        local old_sync_all = sync_instance.manager.syncAllChangedDocuments
        sync_instance.manager.syncAllChangedDocuments = function(this)
            sync_all_called = true
            pending_at_call = changed_documents.get_pending()
        end

        sync_instance.manager:scanAndSyncAllBooks()

        ConfirmBox.new = old_ConfirmBox_new
        sync_instance.manager.syncAllChangedDocuments = old_sync_all

        assert.is_true(sync_all_called, "Sync All should be triggered automatically after marking books dirty")
        assert.is_equal(1, pending_at_call)
        local count, pending = changed_documents.get_pending()
        assert.is_true(pending[book] == true)
    end)

    it("does not mark or sync anything when every book is already empty of annotations", function()
        make_book("empty.epub")

        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = auto_confirm()

        local sync_all_called = false
        local old_sync_all = sync_instance.manager.syncAllChangedDocuments
        sync_instance.manager.syncAllChangedDocuments = function(this)
            sync_all_called = true
        end

        sync_instance.manager:scanAndSyncAllBooks()

        ConfirmBox.new = old_ConfirmBox_new
        sync_instance.manager.syncAllChangedDocuments = old_sync_all

        assert.is_false(sync_all_called)
    end)

    it("does not scan at all when the user cancels the confirmation dialog", function()
        make_book("book1.epub")

        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = ConfirmBox.new
        ConfirmBox.new = function(this, o)
            -- Simulate the user tapping Cancel: never invoke ok_callback.
            return { onShow = function() end, paintTo = function() end, free = function() end, handleEvent = function() end }
        end

        local subprocess_called = false
        Trapper.dismissableRunInSubprocess = function(this, func, trap_widget_or_string)
            subprocess_called = true
            return true, func()
        end

        sync_instance.manager:scanAndSyncAllBooks()

        ConfirmBox.new = old_ConfirmBox_new

        assert.is_false(subprocess_called, "Scanning should not start until the user confirms")
    end)

    it("does not mark or sync anything when the scan is cancelled", function()
        local book = make_book("book1.epub")
        give_annotations(book, {{ page = 1, text = "hi" }})

        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = auto_confirm()

        Trapper.dismissableRunInSubprocess = function(this, func, trap_widget_or_string)
            return false -- user cancelled mid-scan
        end

        local sync_all_called = false
        local old_sync_all = sync_instance.manager.syncAllChangedDocuments
        sync_instance.manager.syncAllChangedDocuments = function(this)
            sync_all_called = true
        end

        sync_instance.manager:scanAndSyncAllBooks()

        ConfirmBox.new = old_ConfirmBox_new
        sync_instance.manager.syncAllChangedDocuments = old_sync_all

        assert.is_false(sync_all_called)
        assert.is_equal(0, (changed_documents.get_pending()))
    end)

    it("honors progress_sync_excluded_dirs when scanning", function()
        local excluded_dir = library_dir .. "/excluded"
        local book = make_book("excluded/book.epub")
        give_annotations(book, {{ page = 1, text = "hi" }})
        sync_instance.settings.progress_sync_excluded_dirs = { excluded_dir }

        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = auto_confirm()

        local sync_all_called = false
        local old_sync_all = sync_instance.manager.syncAllChangedDocuments
        sync_instance.manager.syncAllChangedDocuments = function(this)
            sync_all_called = true
        end

        sync_instance.manager:scanAndSyncAllBooks()

        ConfirmBox.new = old_ConfirmBox_new
        sync_instance.manager.syncAllChangedDocuments = old_sync_all
        sync_instance.settings.progress_sync_excluded_dirs = {}

        assert.is_false(sync_all_called, "A book in an excluded directory should not be marked or synced")
    end)
end)
