describe("AnnotationSync Settings Persistence", function()
    local UIManager, AnnotationSyncPlugin, test_utils, json
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_settings_persistence_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        UIManager = require("ui/uimanager")
        json = require("json")
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
    end)

    teardown(function()
        if readerui then readerui:onClose() end
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end)

    before_each(function()
        readerui, sync_instance = test_utils.init_integration_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
    end)

    it("should persist progress_sync_interval after change via InputDialog", function()
        local InputDialog = require("ui/widget/inputdialog")
        
        -- 1. Find the menu item for progress_sync_interval
        local menu_items = {}
        sync_instance:addToMainMenu(menu_items)
        local settings_menu = menu_items.annotation_sync_plugin.sub_item_table[1]
        local interval_item
        for _, item in ipairs(settings_menu.sub_item_table) do
            if item.text_func and item.text_func():find("Sync every") then
                interval_item = item
                break
            end
        end
        assert.is_not_nil(interval_item)

        -- 2. Trigger the callback to open InputDialog
        local dialog
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Sync every # pages" then
                dialog = widget
            end
            return old_show(this, widget)
        end
        
        interval_item.callback()
        assert.is_not_nil(dialog)

        -- 3. Simulate saving a new value (e.g., 7)
        dialog.save_callback("7")

        -- 4. Verify local state
        assert.is_equal(7, sync_instance.settings.progress_sync_interval)

        -- 5. Verify persistent state in G_reader_settings
        local saved_settings = G_reader_settings:readSetting(sync_instance.plugin_id)
        assert.is_equal(7, saved_settings.progress_sync_interval)

        UIManager.show = old_show
    end)

    it("should sanitize corrupted settings on init", function()
        -- 1. Mock corrupted settings in G_reader_settings
        G_reader_settings:saveSetting(sync_instance.plugin_id, {
            progress_sync_interval = { some = "table" } -- corrupted
        })

        -- 2. Re-initialize plugin
        sync_instance:init()

        -- 3. Verify it was reset to default (1)
        assert.is_equal(1, sync_instance.settings.progress_sync_interval)
    end)

    it("should use default settings if absent", function()
        -- 1. Delete settings
        G_reader_settings:delSetting(sync_instance.plugin_id)

        -- 2. Re-initialize plugin
        sync_instance:init()

        -- 3. Verify defaults
        assert.is_equal(1, sync_instance.settings.progress_sync_interval)
        assert.is_false(sync_instance.settings.progress_sync)
    end)

    it("should migrate legacy cloud_server_object on init", function()
        -- 1. Setup legacy setting
        local legacy_server = { url = "http://legacy-server", type = "webdav" }
        G_reader_settings:saveSetting("cloud_server_object", json.encode(legacy_server))
        
        -- 2. Clear plugin settings sync_server
        local plugin_settings = G_reader_settings:readSetting(sync_instance.plugin_id) or {}
        plugin_settings.sync_server = nil
        G_reader_settings:saveSetting(sync_instance.plugin_id, plugin_settings)

        -- 3. Re-initialize plugin
        sync_instance:init()

        -- 4. Verify it was migrated
        assert.is_not_nil(sync_instance.settings.sync_server)
        assert.is_equal("http://legacy-server", sync_instance.settings.sync_server.url)
        assert.is_equal("webdav", sync_instance.settings.sync_server.type)

        -- Clean up
        G_reader_settings:delSetting("cloud_server_object")
    end)

    it("should save sync_server and update G_reader_settings on confirmation", function()
        local test_server = { url = "http://test-server-confirm", type = "dropbox" }
        
        -- 1. Call onSyncServiceConfirm
        sync_instance:onSyncServiceConfirm(test_server)

        -- 2. Verify sync_server is updated in settings
        assert.is_not_nil(sync_instance.settings.sync_server)
        assert.is_equal("http://test-server-confirm", sync_instance.settings.sync_server.url)

        -- 3. Verify G_reader_settings keys are updated for compatibility
        local server_json = G_reader_settings:readSetting("cloud_server_object")
        assert.is_not_nil(server_json)
        local saved_server = json.decode(server_json)
        assert.is_equal("http://test-server-confirm", saved_server.url)
        assert.is_equal("http://test-server-confirm", G_reader_settings:readSetting("cloud_download_dir"))
        assert.is_equal("dropbox", G_reader_settings:readSetting("cloud_provider_type"))
    end)
end)
