describe("AnnotationSync Settings Selection", function()
    local UIManager, AnnotationSyncPlugin, test_utils, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_settings_selection_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        UIManager = require("ui/uimanager")
        util = require("util")
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
        sync_instance.path = "plugins/AnnotationSync.koplugin"
        UIManager:show(readerui)
        fastforward_ui_events()
    end)

    it("should initialize empty selected_settings in default settings", function()
        assert.is_not_nil(sync_instance.settings.selected_settings)
        assert.is_equal(type(sync_instance.settings.selected_settings), "table")
    end)

    it("should allow selecting/unselecting settings and persist selections", function()
        -- 1. Create a mock active reader settings file with some changes
        local active_reader = {
            ["auto_standby_timeout_seconds"] = 100, -- changed from default -1
        }
        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write("return " .. sync_instance.manager:_serialize_table(active_reader))
        f:close()

        -- 2. Mock UIManager:show to capture the submenu
        local submenu
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Changed Settings" then
                submenu = widget
            end
            return old_show(this, widget)
        end

        -- 3. Show changed settings
        sync_instance:showChangedSettings()
        assert.is_not_nil(submenu)

        -- 4. Find the mock changed setting item in the submenu's item table
        local changed_item
        local changed_index
        for i, item in ipairs(submenu.item_table) do
            if item.setting_id == "reader:auto_standby_timeout_seconds" then
                changed_item = item
                changed_index = i
                break
            end
        end
        assert.is_not_nil(changed_item)

        -- 5. Toggle the checkbox (initially unchecked)
        assert.is_nil(sync_instance.settings.selected_settings["reader:auto_standby_timeout_seconds"])
        
        -- Call callback to select
        changed_item.callback()
        assert.is_true(sync_instance.settings.selected_settings["reader:auto_standby_timeout_seconds"])

        -- Verify it is saved in G_reader_settings
        local saved = G_reader_settings:readSetting(sync_instance.plugin_id)
        assert.is_true(saved.selected_settings["reader:auto_standby_timeout_seconds"])

        -- Call callback again to deselect
        changed_item.callback()
        assert.is_nil(sync_instance.settings.selected_settings["reader:auto_standby_timeout_seconds"])

        UIManager.show = old_show
    end)

    it("should support Select All and Clear Selection on the menu", function()
        -- 1. Create a mock active reader settings file with changes
        local active_reader = {
            ["auto_standby_timeout_seconds"] = 100,
            ["auto_suspend_timeout_seconds"] = 200,
        }
        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write("return " .. sync_instance.manager:_serialize_table(active_reader))
        f:close()

        local submenu
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Changed Settings" then
                submenu = widget
            end
            return old_show(this, widget)
        end

        sync_instance:showChangedSettings()
        assert.is_not_nil(submenu)

        -- Find Select All and Clear Selection items
        local select_all_item, clear_selection_item
        for _, item in ipairs(submenu.item_table) do
            if item.text == "Select All" then
                select_all_item = item
            elseif item.text == "Clear Selection" then
                clear_selection_item = item
            end
        end
        assert.is_not_nil(select_all_item)
        assert.is_not_nil(clear_selection_item)

        -- Trigger Select All
        select_all_item.callback()
        assert.is_true(sync_instance.settings.selected_settings["reader:auto_standby_timeout_seconds"])
        assert.is_true(sync_instance.settings.selected_settings["reader:auto_suspend_timeout_seconds"])

        -- Trigger Clear Selection
        clear_selection_item.callback()
        assert.is_nil(sync_instance.settings.selected_settings["reader:auto_standby_timeout_seconds"])
        assert.is_nil(sync_instance.settings.selected_settings["reader:auto_suspend_timeout_seconds"])

        UIManager.show = old_show
    end)
end)
