describe("AnnotationSync Backward Compatibility", function()
    local SyncService, UIManager, AnnotationSyncPlugin, test_utils, remote
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_compat_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")
        remote = require("remote")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
        package.loaded["remote"] = nil
    end)

    before_each(function()
        readerui, sync_instance = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
    end)

    it("should fall back to SyncService.sync when widget.ui.cloudstorage is nil", function()
        -- 1. Ensure widget.ui.cloudstorage is nil
        local mock_widget = {
            ui = {}, -- no cloudstorage plugin
            settings = {
                sync_server = { url = "http://mock-server", type = "webdav" }
            }
        }

        -- 2. Mock SyncService.sync to track calls
        local sync_called = false
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, upload_only)
            sync_called = true
            return callback(local_path, local_path, local_path)
        end

        -- 3. Mock annotations.sync_callback
        local annotations = require("annotations")
        local old_sync_callback = annotations.sync_callback
        annotations.sync_callback = function() return true, {} end

        -- 4. Execute sync_annotations
        local success_called = false
        remote.sync_annotations(mock_widget, {}, "dummy.json", function(success)
            success_called = true
        end)

        -- 5. Assert fallback SyncService.sync was used
        assert.is_true(sync_called)
        assert.is_true(success_called)

        -- Cleanup
        SyncService.sync = old_sync
        annotations.sync_callback = old_sync_callback
    end)

    it("should disable progress sync menu options when self.ui.cloudstorage is nil", function()
        -- 1. Remove cloudstorage from readerui
        readerui.cloudstorage = nil
        sync_instance.ui.cloudstorage = nil

        -- 2. Generate menu items
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        local settings_menu = menu_items.annotation_sync_plugin.sub_item_table[1]
        
        -- 3. Verify "Enable Reading Progress Sync" is disabled
        local progress_sync_item
        for _, item in ipairs(settings_menu.sub_item_table) do
            if item.text == "Enable Reading Progress Sync" then
                progress_sync_item = item
                break
            end
        end
        assert.is_not_nil(progress_sync_item)
        assert.is_false(progress_sync_item.enabled_func())

        -- 4. Verify "Jump to device progress" is disabled
        local jump_item
        for _, item in ipairs(menu_items.annotation_sync_plugin.sub_item_table) do
            if item.text == "Jump to device progress" then
                jump_item = item
                break
            end
        end
        assert.is_not_nil(jump_item)
        assert.is_false(jump_item.enabled_func())
    end)

    it("should open legacy SyncService in settings if self.ui.cloudstorage is nil", function()
        -- 1. Remove cloudstorage from readerui
        readerui.cloudstorage = nil
        sync_instance.ui.cloudstorage = nil

        -- 2. Mock UIManager:show to intercept SyncService instance
        local opened_syncservice = false
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            -- Check if it is an instance of SyncService
            if widget.generateItemTable and widget.title == "Cloud sync settings" then
                opened_syncservice = true
                return
            end
            return old_show(this, widget)
        end

        -- 3. Generate menu items
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        local settings_menu = menu_items.annotation_sync_plugin.sub_item_table[1]

        local cloud_settings_item
        for _, item in ipairs(settings_menu.sub_item_table) do
            if item.text == "Cloud settings" then
                cloud_settings_item = item
                break
            end
        end
        assert.is_not_nil(cloud_settings_item)
        assert.is_true(cloud_settings_item.enabled_func())

        -- 4. Trigger callback and verify legacy SyncService dialog is shown
        cloud_settings_item.callback()
        assert.is_true(opened_syncservice)

        -- Cleanup
        UIManager.show = old_show
    end)

    it("should show 'Why are some options greyed out?' menu item at the end of the menu when self.ui.cloudstorage is nil", function()
        -- 1. Remove cloudstorage from readerui
        readerui.cloudstorage = nil
        sync_instance.ui.cloudstorage = nil

        -- 2. Generate menu items
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        local plugin_menu = menu_items.annotation_sync_plugin.sub_item_table
        
        -- 3. Verify the last item is our explanation button
        local last_item = plugin_menu[#plugin_menu]
        assert.is_not_nil(last_item)
        assert.is_nil(last_item.enabled) -- defaults to enabled
        assert.is_equal(last_item.text, "Why are some options greyed out?")
        assert.is_not_nil(last_item.callback)
    end)

    it("should not show 'Why are some options greyed out?' menu item when self.ui.cloudstorage is present", function()
        -- 1. Set mock cloudstorage
        sync_instance.ui.cloudstorage = {}

        -- 2. Generate menu items
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        local plugin_menu = menu_items.annotation_sync_plugin.sub_item_table
        
        -- 3. Verify no explanation button is present anywhere in the menu
        for _, item in ipairs(plugin_menu) do
            if item.text then
                assert.is_nil(item.text:match("Why are some options greyed out%?"))
            end
        end
    end)
end)
