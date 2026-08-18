describe("Purge device from progress sync UI (gh-90)", function()
    local ReaderUI, UIManager, NetworkMgr, Device, Geom
    local AnnotationSyncPlugin, test_utils, json, utils
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_progress_purge_ui_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        NetworkMgr = require("ui/network/manager")
        Device = require("device")
        json = require("json")

        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")
        utils = require("utils")
        _G.utils = utils

        old_getDataDir = test_utils.setup_test_env(test_data_dir)

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
        _G.utils = nil
    end)

    before_each(function()
        UIManager:show(readerui)
        fastforward_ui_events()

        sync_instance.settings.progress_sync = true
        sync_instance.settings.purged_devices = {}
        Device.model = "TestDevice"
        NetworkMgr.isConnected = function() return true end

        readerui.getCurrentPage = function(this) return readerui.document.page or 1 end
        if not readerui.paging then
            readerui.paging = {
                number_of_pages = 100,
                getLastPercent = function(this) return 0 end,
                getLastProgress = function(this) return "mock-pos-123" end
            }
        end
        readerui.document.setPagePosition = function(this, page) end
        readerui.document.gotoPage = function(this, page) this.page = page end
        readerui.document.getPageIndex = function(this) return readerui.document.page or 1 end
        readerui.document.getPercentage = function(this) return 0.1 end
        readerui.document.getNativePageDimensions = function(this, pageno)
            return Geom:new{ w = 1200, h = 1600 }
        end
    end)

    local function current_progress_path()
        local docsettings = require("frontend/docsettings")
        local lfs = require("libs/libkoreader-lfs")
        local util = require("util")
        local sdr_dir = docsettings:getSidecarDir(readerui.document.file)
        if not lfs.attributes(sdr_dir, "mode") then
            util.makePath(sdr_dir)
        end
        return sync_instance.manager, sdr_dir .. "/" .. sync_instance.manager:_getProgressFilename(readerui.document.file)
    end

    it("lists devices from the current document's progress map, excluding the current device", function()
        local manager, json_path = current_progress_path()
        local util = require("util")
        util.writeToFile(json.encode({
            TestDevice = { page = 1, timestamp = "2026-01-01 00:00:00" },
            OtherDevice = { page = 5, timestamp = "2026-01-01 00:00:00" },
        }), json_path, true, false, true)

        local listed = {}
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Purge device from progress sync" then
                for _, item in ipairs(widget.item_table) do
                    table.insert(listed, item.text)
                end
            else
                old_show(this, widget)
            end
        end

        manager:purgeDevicePrompt()

        UIManager.show = old_show
        assert.is_equal(1, #listed)
        assert.is_equal("OtherDevice", listed[1])
    end)

    it("does not duplicate an entry when purging an already-purged device again", function()
        local remote = require("remote")
        local manager = sync_instance.manager
        sync_instance.settings.purged_devices = { "OtherDevice" }

        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            callback(true)
        end

        manager:purgeDevice("OtherDevice")
        fastforward_ui_events()

        remote.push_progress_bg = old_push

        assert.is_equal(1, #sync_instance.settings.purged_devices)
    end)

    it("excludes already-purged devices from the purge picker", function()
        local manager, json_path = current_progress_path()
        local util = require("util")
        util.writeToFile(json.encode({
            OtherDevice = { page = 5, timestamp = "2026-01-01 00:00:00" },
            YetAnotherDevice = { page = 3, timestamp = "2026-01-01 00:00:00" },
        }), json_path, true, false, true)
        sync_instance.settings.purged_devices = { "OtherDevice" }

        local listed = {}
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Purge device from progress sync" then
                for _, item in ipairs(widget.item_table) do
                    table.insert(listed, item.text)
                end
            else
                old_show(this, widget)
            end
        end

        manager:purgeDevicePrompt()

        UIManager.show = old_show
        assert.is_equal(1, #listed)
        assert.is_equal("YetAnotherDevice", listed[1])
    end)

    it("confirming a purge adds the device and immediately pushes the tombstone", function()
        local remote = require("remote")
        local manager, json_path = current_progress_path()
        local util = require("util")
        util.writeToFile(json.encode({
            OtherDevice = { page = 5, timestamp = "2026-01-01 00:00:00" },
        }), json_path, true, false, true)

        local pushed = false
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            pushed = true
            callback(true)
        end

        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Purge device from progress sync" then
                for _, item in ipairs(widget.item_table) do
                    if item.text == "OtherDevice" then item.callback() end
                end
            elseif widget.ok_callback then
                widget.ok_callback()
            else
                old_show(this, widget)
            end
        end

        manager:purgeDevicePrompt()

        UIManager.show = old_show
        remote.push_progress_bg = old_push

        local found = false
        for _, name in ipairs(sync_instance.settings.purged_devices) do
            if name == "OtherDevice" then found = true end
        end
        assert.is_true(found)
        assert.is_true(pushed)

        local written = utils.read_json(json_path)
        assert.is_true(written.OtherDevice.removed)
    end)

    it("canceling the confirmation makes no change to purged_devices or progress data", function()
        local manager, json_path = current_progress_path()
        local util = require("util")
        util.writeToFile(json.encode({
            OtherDevice = { page = 5, timestamp = "2026-01-01 00:00:00" },
        }), json_path, true, false, true)

        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Purge device from progress sync" then
                for _, item in ipairs(widget.item_table) do
                    if item.text == "OtherDevice" then item.callback() end
                end
            elseif widget.cancel_callback then
                widget.cancel_callback()
            end
            -- neither ok_callback nor cancel_callback invoked: simulates dismiss
        end

        manager:purgeDevicePrompt()

        UIManager.show = old_show

        assert.is_equal(0, #sync_instance.settings.purged_devices)
        local unchanged = utils.read_json(json_path)
        assert.is_nil(unchanged.OtherDevice.removed)
    end)

    it("Purged devices screen lists entries and removing one un-purges with a document open", function()
        local remote = require("remote")
        local menus = require("menus")
        local manager, json_path = current_progress_path()
        local util = require("util")
        util.writeToFile(json.encode({
            OtherDevice = { removed = true, timestamp = "2026-01-01 00:00:00" },
        }), json_path, true, false, true)
        sync_instance.settings.purged_devices = { "OtherDevice" }

        local pushed = false
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            pushed = true
            callback(true)
        end

        local listed = {}
        local captured = false
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Purged devices" then
                if not captured then
                    captured = true
                    for _, item in ipairs(widget.item_table) do
                        table.insert(listed, item.text)
                        if item.text == "OtherDevice" then item.callback() end
                    end
                end
            elseif widget.ok_callback then
                widget.ok_callback()
            else
                old_show(this, widget)
            end
        end

        menus.show_purged_devices(sync_instance, function(device_name)
            sync_instance.manager:unpurgeDevice(device_name)
        end)

        UIManager.show = old_show
        remote.push_progress_bg = old_push

        assert.is_equal(1, #listed)
        assert.is_equal("OtherDevice", listed[1])
        assert.is_equal(0, #sync_instance.settings.purged_devices)
        assert.is_true(pushed)

        local written = utils.read_json(json_path)
        assert.is_false(written.OtherDevice.removed)
    end)

    it("removing a purged entry with no document open updates the setting only", function()
        local remote = require("remote")
        local menus = require("menus")
        sync_instance.settings.purged_devices = { "OtherDevice" }

        local old_document = readerui.document
        readerui.document = nil

        local pushed = false
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            pushed = true
            callback(true)
        end

        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Purged devices" then
                for _, item in ipairs(widget.item_table) do
                    if item.text == "OtherDevice" then item.callback() end
                end
            elseif widget.ok_callback then
                widget.ok_callback()
            else
                old_show(this, widget)
            end
        end

        assert.has_no.errors(function()
            menus.show_purged_devices(sync_instance, function(device_name)
                sync_instance.manager:unpurgeDevice(device_name)
            end)
        end)

        UIManager.show = old_show
        remote.push_progress_bg = old_push
        readerui.document = old_document

        assert.is_equal(0, #sync_instance.settings.purged_devices)
        assert.is_false(pushed)
    end)

    it("a purged device no longer appears in Jump to device progress", function()
        local menus = require("menus")
        local remote_data = {
            OtherDevice = { removed = true, page = 5, timestamp = "2026-01-01 00:00:00" },
            ActiveDevice = { page = 10, percentage = 0.5, timestamp = "2026-01-01 00:00:00" },
        }

        local listed = {}
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Jump to device progress" then
                for _, item in ipairs(widget.item_table) do
                    table.insert(listed, item.text)
                end
            else
                old_show(this, widget)
            end
        end

        menus.show_jump_menu(sync_instance, remote_data)

        UIManager.show = old_show
        assert.is_equal(1, #listed)
        assert.is_true(listed[1]:find("ActiveDevice") ~= nil)
    end)

    it("a purged device no longer appears in the other devices' settings list", function()
        local menus = require("menus")
        sync_instance.settings.purged_devices = { "OtherDevice" }
        local settings_map = {
            OtherDevice = { timestamp = "2026-01-01 00:00:00", settings = {} },
            ActiveDevice = { timestamp = "2026-01-01 00:00:00", settings = {} },
        }

        local listed = {}
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Pull settings from cloud" then
                for _, item in ipairs(widget.item_table) do
                    table.insert(listed, item.text)
                end
            else
                old_show(this, widget)
            end
        end

        menus.show_devices_menu(sync_instance, settings_map)

        UIManager.show = old_show
        assert.is_equal(1, #listed)
        assert.is_true(listed[1]:find("ActiveDevice") ~= nil)
    end)
end)
