describe("AnnotationSync Settings Synchronization", function()
    local UIManager, AnnotationSyncPlugin, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_settings_sync_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        UIManager = require("ui/uimanager")
        json = require("json")
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

    it("should return nil from getSelectedSettingsWithValues when selected_settings is empty", function()
        sync_instance.settings.selected_settings = {}
        local res = sync_instance.manager:getSelectedSettingsWithValues()
        assert.is_nil(res)
    end)

    it("should retrieve selected settings with correct active values", function()
        -- Mock active reader settings
        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write([[
return {
    ["auto_standby_timeout_seconds"] = 120,
    ["footer"] = {
        ["time"] = true
    }
}
]])
        f:close()

        -- Select some settings
        sync_instance.settings.selected_settings = {
            ["reader:auto_standby_timeout_seconds"] = true,
            ["reader:footer.time"] = true
        }

        local values = sync_instance.manager:getSelectedSettingsWithValues()
        assert.is_not_nil(values)
        assert.is_equal(120, values["reader:auto_standby_timeout_seconds"])
        assert.is_equal(true, values["reader:footer.time"])
    end)

    it("should correctly write local file and sync it using remote.push_settings", function()
        -- Configure mock sync server
        local test_server = { url = "http://test-server-settings", type = "webdav" }
        sync_instance:onSyncServiceConfirm(test_server)

        -- Mock active settings
        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write([[
return {
    ["auto_suspend_timeout_seconds"] = 300
}
]])
        f:close()

        -- Select the setting
        sync_instance.settings.selected_settings = {
            ["reader:auto_suspend_timeout_seconds"] = true
        }

        -- Set custom device name
        sync_instance.settings.device_name = "TestDeviceX"

        -- Mock SyncService to assert the values being synced
        local sync_called = false
        local remote_file_content = nil
        
        local SyncService = require("apps/cloudstorage/syncservice")
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            sync_called = true
            -- Create a fake remote/income file with another device's settings
            local income_path = local_path .. ".income"
            local other_device_data = {
                ["OtherDevice"] = {
                    settings = {
                        ["reader:auto_standby_timeout_seconds"] = 15
                    },
                    timestamp = "2026-06-06 12:00:00"
                }
            }
            local fi = io.open(income_path, "w")
            fi:write(json.encode(other_device_data))
            fi:close()

            local success, merged = callback(local_path, local_path .. ".last_sync", income_path)
            assert.is_true(success)

            -- Read local_path after callback to verify the merge
            local fl = io.open(local_path, "r")
            remote_file_content = fl:read("*a")
            fl:close()

            os.remove(income_path)
            return true
        end

        sync_instance.manager:pushSettings()
        assert.is_true(sync_called)

        -- Restore mock
        SyncService.sync = old_sync

        -- Verify that the synced file has both this device's and other device's settings
        assert.is_not_nil(remote_file_content)
        local data = json.decode(remote_file_content)
        assert.is_not_nil(data["TestDeviceX"])
        assert.is_equal(300, data["TestDeviceX"].settings["reader:auto_suspend_timeout_seconds"])
        assert.is_not_nil(data["OtherDevice"])
        assert.is_equal(15, data["OtherDevice"].settings["reader:auto_standby_timeout_seconds"])
    end)
end)
