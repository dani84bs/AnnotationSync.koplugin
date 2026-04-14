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
end)
