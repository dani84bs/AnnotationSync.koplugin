describe("Unsynced / Pending Documents Feature", function()
    local ReaderUI, UIManager, SyncService, Geom
    local AnnotationSyncPlugin, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_unsynced_docs_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        json = require("json")
        util = require("util")
        
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

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
        os.remove(sync_instance.manager:changedDocumentsFile())
    end)

    it("verifies that Sync All tracks failed files correctly and triggers the UI warning", function()
        -- 1. Setup two changed documents
        local file1 = readerui.document.file
        local file2 = test_data_dir .. "/missing_file.epub"
        
        -- Write a dummy file for file2 so it exists (otherwise it is automatically removed as missing)
        local f = io.open(file2, "w")
        f:write("dummy")
        f:close()

        sync_instance.manager:addToChangedDocumentsFile(file1)
        sync_instance.manager:addToChangedDocumentsFile(file2)

        -- 2. Mock SyncService to fail for file1, and mock getDocumentByFile to crash or fail for file2
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            -- Simulate failure by returning nil
            return nil
        end

        local old_getDoc = sync_instance.manager.getDocumentByFile
        sync_instance.manager.getDocumentByFile = function(this, file)
            if file == file1 then
                return readerui.document
            else
                -- Return nil (could not open document)
                return nil
            end
        end

        local confirm_shown = false
        local confirm_text = ""
        local ConfirmBox = require("ui/widget/confirmbox")
        local old_ConfirmBox_new = ConfirmBox.new
        ConfirmBox.new = function(this, o)
            confirm_shown = true
            confirm_text = o.text or ""
            local mock = setmetatable(o or {}, { __index = ConfirmBox })
            mock.handleEvent = function() end
            return mock
        end

        local messages = {}
        local old_show_msg = require("utils").show_msg
        require("utils").show_msg = function(msg)
            table.insert(messages, msg)
        end

        -- 3. Run Sync All
        sync_instance.manager:syncAllChangedDocuments()
        fastforward_ui_events()

        -- 4. Verify results
        assert.is_true(confirm_shown, "A warning dialog should have been shown")
        assert.truthy(confirm_text:match("juliet%.epub"), "Popup should list juliet.epub")
        assert.truthy(confirm_text:match("missing_file%.epub"), "Popup should list missing_file.epub")

        -- Cleanup
        SyncService.sync = old_sync
        sync_instance.manager.getDocumentByFile = old_getDoc
        require("ui/widget/confirmbox").new = old_ConfirmBox_new
        require("utils").show_msg = old_show_msg
        os.remove(file2)
    end)

    it("verifies that show_pending_documents constructs the menu and handles actions correctly", function()
        local file1 = readerui.document.file
        sync_instance.manager:addToChangedDocumentsFile(file1)

        local menus = require("menus")
        local Menu = require("ui/widget/menu")
        local ConfirmBox = require("ui/widget/confirmbox")

        local menu_shown = false
        local menu_items = {}
        local old_Menu_new = Menu.new
        Menu.new = function(this, o)
            menu_shown = true
            menu_items = o.item_table or {}
            return {
                onShow = function() end,
                paintTo = function() end,
                free = function() end,
                handleEvent = function() end,
            }
        end

        local confirm_shown = false
        local confirm_opts = {}
        local old_ConfirmBox_new = ConfirmBox.new
        ConfirmBox.new = function(this, o)
            confirm_shown = true
            confirm_opts = o
            return {
                onShow = function() end,
                paintTo = function() end,
                free = function() end,
                handleEvent = function() end,
            }
        end

        -- 1. Show pending documents menu
        menus.show_pending_documents(sync_instance)

        assert.is_true(menu_shown)
        assert.is_equal(1, #menu_items)
        assert.is_equal("juliet.epub", menu_items[1].text)

        -- 2. Emulate tapping the document
        menu_items[1].callback()
        assert.is_true(confirm_shown)
        assert.truthy(confirm_opts.text:match("juliet%.epub"))
        assert.is_not_nil(confirm_opts.other_buttons)

        -- 3. Emulate clicking "Remove from list"
        confirm_opts.other_buttons[1][1].callback()

        -- Check that it is removed
        local count, _ = sync_instance.manager:getPendingChangedDocuments()
        assert.is_equal(0, count, "Document should be removed from changed list")

        -- Cleanup
        Menu.new = old_Menu_new
        ConfirmBox.new = old_ConfirmBox_new
    end)
end)
