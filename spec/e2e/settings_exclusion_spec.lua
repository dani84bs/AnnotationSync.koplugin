-- E2E: settings push exclusion filter, over a real local WebDAV server.
--
-- Proves ticket 15's push-boundary filter end-to-end: an excluded key
-- forced directly into `selected_settings` (bypassing the selection menu)
-- never reaches the remote JSON, while a legitimately selected setting
-- does -- driven by the real `AnnotationSyncPushSettings` KOReader Event,
-- the same dispatch path a menu tap takes, with a real WebDAV round trip.
describe("AnnotationSync E2E settings exclusion", function()
    local Event, ReaderUI, UIManager, json, WebDavApi
    local AnnotationSyncPlugin, test_utils, e2e_test_utils

    local function fetch_remote_settings_sync()
        local server = e2e_test_utils.server_config()
        local remote_path = WebDavApi:getJoinedPath(server.address, server.url)
        remote_path = WebDavApi:getJoinedPath(remote_path, "settings_sync.json")

        local tmp_path = os.getenv("PWD") .. "/.settings_exclusion_fetch.json"
        local code = WebDavApi:downloadFile(remote_path, server.username, server.password, tmp_path)
        if not code or code < 200 or code >= 300 then
            os.remove(tmp_path)
            return nil, code
        end

        local f = io.open(tmp_path, "r")
        local content = f:read("*a")
        f:close()
        os.remove(tmp_path)
        return json.decode(content)
    end

    local function push_settings(test_data_dir, device_name, reader_settings_lua, selected_settings)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)

        local f = io.open(test_data_dir .. "/settings.reader.lua", "w")
        f:write(reader_settings_lua)
        f:close()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            "spec/front/unit/data/juliet.epub", AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.device_name = device_name
        sync_instance.settings.selected_settings = selected_settings

        readerui:handleEvent(Event:new("AnnotationSyncPushSettings"))
        fastforward_ui_events()

        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        UIManager:quit()
        package.loaded["main"] = nil
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        json = require("json")
        WebDavApi = require("apps/cloudstorage/webdavapi")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
    end)

    it("pushes a legitimate selected setting to the real WebDAV server", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_settings_exclusion_happy_tmp"
        os.execute("mkdir -p " .. test_data_dir)

        push_settings(test_data_dir, "SettingsExclusionE2E-Happy", [[
return {
    ["auto_suspend_timeout_seconds"] = 300
}
]], {
            ["reader:auto_suspend_timeout_seconds"] = true,
        })

        local data = fetch_remote_settings_sync()
        assert.is_not_nil(data)
        assert.is_not_nil(data["SettingsExclusionE2E-Happy"])
        local settings = data["SettingsExclusionE2E-Happy"].settings
        assert.is_equal(300, settings["reader:auto_suspend_timeout_seconds"])
        assert.is_nil(settings["reader:cloud_server_object"])
        assert.is_nil(settings["reader:device_id"])
        assert.is_nil(settings["reader:AnnotationSync"])
    end)

    it("never pushes excluded keys forced directly into selected_settings", function()
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_settings_exclusion_adversarial_tmp"
        os.execute("mkdir -p " .. test_data_dir)

        push_settings(test_data_dir, "SettingsExclusionE2E-Adversarial", [[
return {
    ["auto_suspend_timeout_seconds"] = 300,
    ["device_id"] = "forced-device-id",
    ["cloud_server_object"] = "{\"type\":\"webdav\"}",
    ["AnnotationSync"] = { foo = "bar" }
}
]], {
            -- Legitimate setting, plus 4 representative excluded keys
            -- bypassing the selection menu (ticket 15's push()-boundary
            -- filter is what has to stop these, not the menu).
            ["reader:auto_suspend_timeout_seconds"] = true,
            ["reader:device_id"] = true,
            ["reader:cloud_server_object"] = true,
            ["reader:AnnotationSync"] = true,
            ["settings/statistics:total_read_pages"] = true,
        })

        local data = fetch_remote_settings_sync()
        assert.is_not_nil(data)
        local settings = data["SettingsExclusionE2E-Adversarial"].settings
        assert.is_equal(300, settings["reader:auto_suspend_timeout_seconds"])
        assert.is_nil(settings["reader:device_id"])
        assert.is_nil(settings["reader:cloud_server_object"])
        assert.is_nil(settings["reader:AnnotationSync"])
        assert.is_nil(settings["settings/statistics:total_read_pages"])
    end)
end)
