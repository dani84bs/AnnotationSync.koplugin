describe("Reading Progress Sync Integration", function()
    local ReaderUI, UIManager, SyncService, NetworkMgr, Device, Geom
    local AnnotationSyncPlugin, test_utils, json, util
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_progress_sync_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        disable_plugins()
        Geom = require("ui/geometry")
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        NetworkMgr = require("ui/network/manager")
        Device = require("device")
        json = require("json")
        util = require("util")
        
        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

        -- Mock utils globally because remote.lua is missing the require
        _G.utils = require("utils")

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
        
        -- Enable progress sync and set interval to 2 for testing
        sync_instance.settings.progress_sync = true
        sync_instance.settings.progress_sync_interval = 2
        sync_instance.manager.page_turn_counter = 0
        sync_instance.manager.last_page = 0
        sync_instance.manager.is_syncing = false
        
        -- Mock Network connected by default
        NetworkMgr.isWifiOn = function() return true end
        NetworkMgr.isConnected = function() return true end
        
        -- Mock Device model
        Device.model = "TestDevice"

        -- Mock UI and paging methods to match new manager.lua implementation
        readerui.getCurrentPage = function(this) return readerui.document.page or 1 end
        if not readerui.paging then
            readerui.paging = {
                number_of_pages = 100,
                getLastPercent = function(this) return 0 end,
                getLastProgress = function(this) return "mock-pos-123" end
            }
        else
            readerui.paging.getLastPercent = function(this) return 0 end
            readerui.paging.getLastProgress = function(this) return "mock-pos-123" end
        end

        -- Mock document methods to avoid crashes
        readerui.document.setPagePosition = function(this, page) end
        readerui.document.gotoPage = function(this, page) this.page = page end
        readerui.document.getPageIndex = function(this) return readerui.document.page or 1 end
        readerui.document.getPercentage = function(this) return 0.1 end
        readerui.document.getNativePageDimensions = function(this, pageno)
            return Geom:new{ w = 1200, h = 1600 }
        end
    end)

    it("increments counter and triggers sync every X pages", function()
        local remote = require("remote")
        local push_called = 0
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            push_called = push_called + 1
            callback(true)
        end

        -- Page 1: counter becomes 1
        readerui.document.page = 1
        sync_instance:onPageUpdate()
        assert.is_equal(0, push_called)
        assert.is_equal(1, sync_instance.manager.page_turn_counter)

        -- Page 2: counter becomes 2, triggers sync, resets to 0
        readerui.document.page = 2
        sync_instance:onPageUpdate()
        fastforward_ui_events() -- Trigger scheduled sync (debounce)
        fastforward_ui_events() -- Trigger nested sync schedule
        assert.is_equal(1, push_called)
        assert.is_equal(0, sync_instance.manager.page_turn_counter)

        -- Page 3: counter becomes 1
        readerui.document.page = 3
        sync_instance:onPageUpdate()
        assert.is_equal(1, push_called)
        assert.is_equal(1, sync_instance.manager.page_turn_counter)

        -- Page 4: counter becomes 2, triggers sync, resets to 0
        readerui.document.page = 4
        sync_instance:onPageUpdate()
        fastforward_ui_events() -- Trigger scheduled sync (debounce)
        fastforward_ui_events() -- Trigger nested sync schedule
        assert.is_equal(2, push_called)
        assert.is_equal(0, sync_instance.manager.page_turn_counter)

        remote.push_progress_bg = old_push
    end)

    it("skips sync when network is disconnected", function()
        NetworkMgr.isConnected = function() return false end
        
        local remote = require("remote")
        local push_called = 0
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            push_called = push_called + 1
            callback(true)
        end

        -- Trigger sync (interval is 2, so 2 updates)
        readerui.document.page = 1
        sync_instance:onPageUpdate()
        readerui.document.page = 2
        sync_instance:onPageUpdate()
        fastforward_ui_events()
        
        assert.is_equal(0, push_called)
        
        remote.push_progress_bg = old_push
    end)

    it("stores a map of devices in progress.json", function()
        local remote = require("remote")
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end

        -- Trigger sync
        readerui.document.page = 5
        sync_instance:onPageUpdate()
        readerui.document.page = 6
        sync_instance:onPageUpdate()
        fastforward_ui_events() -- Trigger scheduled sync

        local hash = util.partialMD5(readerui.document.file)
        local sdr_dir = require("docsettings"):getSidecarDir(readerui.document.file)
        local json_path = sdr_dir .. "/" .. hash .. ".progress.json"
        
        local f = io.open(json_path, "r")
        assert.is_not_nil(f)
        local content = f:read("*all")
        f:close()
        
        local data = json.decode(content)
        assert.is_not_nil(data["TestDevice"])
        assert.is_equal(6, data["TestDevice"].page)
        assert.is_not_nil(data["TestDevice"].timestamp)
        -- 6 / 100 = 0.06
        assert.is_equal(0.06, data["TestDevice"].percentage)
        
        remote.push_progress_bg = old_push
    end)

    it("prioritizes getLastPercent() from paging module", function()
        local remote = require("remote")
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end

        -- Mock getLastPercent to return a specific value
        readerui.paging.getLastPercent = function(this) return 0.75 end
        
        -- Trigger sync
        readerui.document.page = 10
        -- total is 100, so manual calculation would be 0.1
        sync_instance:onPageUpdate()
        readerui.document.page = 11
        sync_instance:onPageUpdate()
        fastforward_ui_events()

        local hash = util.partialMD5(readerui.document.file)
        local sdr_dir = require("docsettings"):getSidecarDir(readerui.document.file)
        local json_path = sdr_dir .. "/" .. hash .. ".progress.json"
        
        local f = io.open(json_path, "r")
        local content = f:read("*all")
        f:close()
        
        local data = json.decode(content)
        -- Should be 0.75, not 11/100 = 0.11
        assert.is_equal(0.75, data["TestDevice"].percentage)
        
        remote.push_progress_bg = old_push
    end)

    it("displays remote entries in jump menu and allows jumping", function()
        local remote = require("remote")
        local device_id = "RemoteDevice"
        local remote_data = {
            [device_id] = {
                page = 10,
                percentage = 0.5,
                timestamp = "2026-04-14 12:00:00"
            }
        }

        local old_pull = remote.pull_progress
        remote.pull_progress = function(widget, path, callback)
            callback(true, remote_data)
        end

        local menu_shown = false
        local old_UIManager_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Jump to device progress" then
                menu_shown = true
                -- Simulate clicking the remote device entry
                for _, item in ipairs(widget.item_table) do
                    if item.text:find(device_id) then
                        item.callback()
                        break
                    end
                end
            else
                old_UIManager_show(this, widget)
            end
        end

        local jump_event_fired = false
        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(this, event)
            if event.handler == "onJumpToPage" and (event.args == 10 or (type(event.args) == "table" and event.args[1] == 10)) then
                jump_event_fired = true
            end
            old_broadcast(this, event)
        end

        sync_instance.manager:pullProgress()

        assert.is_true(menu_shown)
        assert.is_true(jump_event_fired)
        assert.is_equal(10, readerui.document:getPageIndex())

        UIManager.show = old_UIManager_show
        UIManager.broadcastEvent = old_broadcast
        remote.pull_progress = old_pull
    end)

    it("includes 'pos' field in progress.json when available", function()
        local remote = require("remote")
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end

        -- Trigger sync
        readerui.document.page = 5
        sync_instance:onPageUpdate()
        readerui.document.page = 6
        sync_instance:onPageUpdate()
        fastforward_ui_events() -- Trigger scheduled sync

        local hash = util.partialMD5(readerui.document.file)
        local sdr_dir = require("docsettings"):getSidecarDir(readerui.document.file)
        local json_path = sdr_dir .. "/" .. hash .. ".progress.json"
        
        local f = io.open(json_path, "r")
        assert.is_not_nil(f)
        local content = f:read("*all")
        f:close()
        
        local data = json.decode(content)
        assert.is_not_nil(data["TestDevice"])
        assert.is_equal("mock-pos-123", data["TestDevice"].pos)
        
        remote.push_progress_bg = old_push
    end)

    it("prioritizes 'GotoPos' when 'pos' is present in remote data", function()
        local remote = require("remote")
        local device_id = "RemoteDevice"
        local remote_data = {
            [device_id] = {
                page = 10,
                percentage = 0.5,
                pos = "remote-pos-456",
                timestamp = "2026-04-14 12:00:00"
            }
        }

        local old_pull = remote.pull_progress
        remote.pull_progress = function(widget, path, callback)
            callback(true, remote_data)
        end

        local menu_shown = false
        local old_UIManager_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Jump to device progress" then
                menu_shown = true
                -- Simulate clicking the remote device entry
                for _, item in ipairs(widget.item_table) do
                    if item.text:find(device_id) then
                        item.callback()
                        break
                    end
                end
            else
                old_UIManager_show(this, widget)
            end
        end

        local goto_pos_fired = false
        local old_onGotoLink
        if readerui.link then
            old_onGotoLink = readerui.link.onGotoLink
            readerui.link.onGotoLink = function(this, target)
                if target.xpointer == "remote-pos-456" then
                    goto_pos_fired = true
                end
            end
        end

        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(this, event)
            if event.handler == "onGotoPos" and event.args[1] == "remote-pos-456" then
                goto_pos_fired = true
            end
            old_broadcast(this, event)
        end

        sync_instance.manager:pullProgress()

        assert.is_true(menu_shown)
        assert.is_true(goto_pos_fired)

        UIManager.show = old_UIManager_show
        UIManager.broadcastEvent = old_broadcast
        remote.pull_progress = old_pull
        if readerui.link and old_onGotoLink then
            readerui.link.onGotoLink = old_onGotoLink
        end
    end)

    it("falls back to 'GotoPage' when 'pos' is missing in remote data", function()
        local remote = require("remote")
        local device_id = "RemoteDevice"
        local remote_data = {
            [device_id] = {
                page = 10,
                percentage = 0.5,
                timestamp = "2026-04-14 12:00:00"
            }
        }

        local old_pull = remote.pull_progress
        remote.pull_progress = function(widget, path, callback)
            callback(true, remote_data)
        end

        local menu_shown = false
        local old_UIManager_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Jump to device progress" then
                menu_shown = true
                -- Simulate clicking the remote device entry
                for _, item in ipairs(widget.item_table) do
                    if item.text:find(device_id) then
                        item.callback()
                        break
                    end
                end
            else
                old_UIManager_show(this, widget)
            end
        end

        local jump_to_page_fired = false
        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(this, event)
            if event.handler == "onJumpToPage" and event.args[1] == 10 then
                jump_to_page_fired = true
            end
            old_broadcast(this, event)
        end

        sync_instance.manager:pullProgress()

        assert.is_true(menu_shown)
        assert.is_true(jump_to_page_fired)

        UIManager.show = old_UIManager_show
        UIManager.broadcastEvent = old_broadcast
        remote.pull_progress = old_pull
    end)

    it("handles pullProgress when local progress file and directory are missing", function()
        local remote = require("remote")
        local docsettings = require("frontend/docsettings")
        local device_id = "RemoteDevice"
        local remote_data = {
            [device_id] = {
                page = 10,
                percentage = 0.5,
                timestamp = "2026-04-14 12:00:00"
            }
        }

        local test_sdr_dir = test_data_dir .. "/non_existent_sdr"
        local hash = util.partialMD5(readerui.document.file)
        local json_path = test_sdr_dir .. "/" .. hash .. ".progress.json"

        -- Mock getSidecarDir to return a unique temp directory
        local old_getSidecarDir = docsettings.getSidecarDir
        docsettings.getSidecarDir = function(this, file)
            return test_sdr_dir
        end

        -- Ensure the temp directory doesn't exist
        os.execute("rm -rf " .. test_sdr_dir)
        assert.is_nil(require("libs/libkoreader-lfs").attributes(test_sdr_dir, "mode"))

        local old_pull = remote.pull_progress
        local dir_existed_on_pull = false
        local file_existed_on_pull = false

        remote.pull_progress = function(widget, path, callback)
            dir_existed_on_pull = (require("libs/libkoreader-lfs").attributes(test_sdr_dir, "mode") == "directory")
            local f = io.open(path, "r")
            if f then
                file_existed_on_pull = true
                f:close()
            end
            callback(true, remote_data)
        end

        local menu_shown = false
        local old_UIManager_show = UIManager.show
        UIManager.show = function(this, widget)
            if widget.title == "Jump to device progress" then
                menu_shown = true
                for _, item in ipairs(widget.item_table) do
                    if item.text:find(device_id) then
                        item.callback()
                        break
                    end
                end
            else
                old_UIManager_show(this, widget)
            end
        end

        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(this, event) end

        sync_instance.manager:pullProgress()

        assert.is_true(dir_existed_on_pull)
        assert.is_true(file_existed_on_pull)
        assert.is_true(menu_shown)

        UIManager.show = old_UIManager_show
        UIManager.broadcastEvent = old_broadcast
        remote.pull_progress = old_pull
        docsettings.getSidecarDir = old_getSidecarDir
        os.execute("rm -rf " .. test_sdr_dir)
    end)

    it("retrieves progress from rolling module when paging is missing", function()
        local remote = require("remote")
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end

        -- Save original values
        local old_paging = readerui.paging
        local old_rolling = readerui.rolling

        -- Remove paging and add rolling
        readerui.paging = nil
        readerui.rolling = {
            getLastPercent = function(this) return 0.88 end,
            getLastProgress = function(this) return "rolling-pos-789" end
        }
        
        -- Trigger sync
        readerui.document.page = 20
        sync_instance:onPageUpdate()
        readerui.document.page = 21
        sync_instance:onPageUpdate()
        fastforward_ui_events()

        local hash = util.partialMD5(readerui.document.file)
        local sdr_dir = require("docsettings"):getSidecarDir(readerui.document.file)
        local json_path = sdr_dir .. "/" .. hash .. ".progress.json"
        
        local f = io.open(json_path, "r")
        local content = f:read("*all")
        f:close()
        
        local data = json.decode(content)
        assert.is_equal(0.88, data["TestDevice"].percentage)
        assert.is_equal("rolling-pos-789", data["TestDevice"].pos)
        
        -- Clean up
        readerui.paging = old_paging
        readerui.rolling = old_rolling
        remote.push_progress_bg = old_push
    end)

    it("resolves pos to the last-but-3 word of the page for reflowable documents in page mode when setting is enabled", function()
        local remote = require("remote")
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end

        -- Save and set up mock view
        local old_view = readerui.view
        readerui.view = { view_mode = "page" }

        -- Mock settings.progress_sync_last_word to true
        sync_instance.settings.progress_sync_last_word = true

        -- Mock getPageXPointer, getPrevVisibleWordStart, and isXPointerInDocument on document
        local old_getPageXPointer = readerui.document.getPageXPointer
        local old_getPrevVisibleWordStart = readerui.document.getPrevVisibleWordStart
        local old_isXPointerInDocument = readerui.document.isXPointerInDocument

        readerui.document.getPageXPointer = function(this, page)
            if page == 7 then
                return "next-page-pos-xp"
            end
        end
        readerui.document.getPrevVisibleWordStart = function(this, xp)
            if xp == "next-page-pos-xp" then
                return "last-word-pos-xp"
            elseif xp == "last-word-pos-xp" then
                return "second-to-last-word-pos-xp"
            elseif xp == "second-to-last-word-pos-xp" then
                return "third-to-last-word-pos-xp"
            end
        end
        readerui.document.isXPointerInDocument = function(this, xp)
            if xp == "mock-pos-123" then
                return true
            end
        end

        -- Trigger sync at page 6 (so next page is 7)
        readerui.document.page = 5
        sync_instance:onPageUpdate()
        readerui.document.page = 6
        sync_instance:onPageUpdate()
        fastforward_ui_events()

        local hash = util.partialMD5(readerui.document.file)
        local sdr_dir = require("docsettings"):getSidecarDir(readerui.document.file)
        local json_path = sdr_dir .. "/" .. hash .. ".progress.json"

        local f = io.open(json_path, "r")
        local content = f:read("*all")
        f:close()

        local data = json.decode(content)
        assert.is_equal("third-to-last-word-pos-xp", data["TestDevice"].pos)

        -- Clean up
        sync_instance.settings.progress_sync_last_word = false
        readerui.view = old_view
        readerui.document.getPageXPointer = old_getPageXPointer
        readerui.document.getPrevVisibleWordStart = old_getPrevVisibleWordStart
        readerui.document.isXPointerInDocument = old_isXPointerInDocument
        remote.push_progress_bg = old_push
    end)

    it("keeps default first-word behavior when settings.progress_sync_last_word is false (default)", function()
        local remote = require("remote")
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end

        -- Save and set up mock view
        local old_view = readerui.view
        readerui.view = { view_mode = "page" }

        -- settings.progress_sync_last_word is false by default

        -- Mock getPageXPointer, getPrevVisibleWordStart, and isXPointerInDocument on document
        local old_getPageXPointer = readerui.document.getPageXPointer
        local old_getPrevVisibleWordStart = readerui.document.getPrevVisibleWordStart
        local old_isXPointerInDocument = readerui.document.isXPointerInDocument

        readerui.document.getPageXPointer = function(this, page)
            if page == 7 then
                return "next-page-pos-xp"
            end
        end
        readerui.document.getPrevVisibleWordStart = function(this, xp)
            if xp == "next-page-pos-xp" then
                return "last-word-pos-xp"
            end
        end
        readerui.document.isXPointerInDocument = function(this, xp)
            if xp == "mock-pos-123" then
                return true
            end
        end

        -- Trigger sync at page 6 (so next page is 7)
        readerui.document.page = 5
        sync_instance:onPageUpdate()
        readerui.document.page = 6
        sync_instance:onPageUpdate()
        fastforward_ui_events()

        local hash = util.partialMD5(readerui.document.file)
        local sdr_dir = require("docsettings"):getSidecarDir(readerui.document.file)
        local json_path = sdr_dir .. "/" .. hash .. ".progress.json"

        local f = io.open(json_path, "r")
        local content = f:read("*all")
        f:close()

        local data = json.decode(content)
        -- Should keep the mock-pos-123 (first word of page)
        assert.is_equal("mock-pos-123", data["TestDevice"].pos)

        -- Clean up
        readerui.view = old_view
        readerui.document.getPageXPointer = old_getPageXPointer
        readerui.document.getPrevVisibleWordStart = old_getPrevVisibleWordStart
        readerui.document.isXPointerInDocument = old_isXPointerInDocument
        remote.push_progress_bg = old_push
    end)

    it("debounces progress sync and queues pending syncs when already syncing", function()
        local remote = require("remote")
        local push_called = 0
        local old_push = remote.push_progress_bg
        local cb_trigger
        
        remote.push_progress_bg = function(widget, path, callback)
            push_called = push_called + 1
            cb_trigger = callback
        end

        -- Page 1 -> 2: triggers interval (interval = 2)
        readerui.document.page = 1
        sync_instance:onPageUpdate()
        readerui.document.page = 2
        sync_instance:onPageUpdate()

        -- No push called immediately because of 3s debounce timer
        assert.is_equal(0, push_called)

        -- Fast forward events to run the 3s timer and the 0.1s nested schedule
        fastforward_ui_events()
        fastforward_ui_events()
        assert.is_equal(1, push_called)
        
        -- While the first sync is running (cb_trigger not called yet, so is_syncing is true),
        -- turn pages again to trigger another sync schedule
        readerui.document.page = 3
        sync_instance:onPageUpdate()
        readerui.document.page = 4
        sync_instance:onPageUpdate()

        -- Wait for debounce timer to fire
        fastforward_ui_events()
        -- Should still be 1 because is_syncing is true, but has_pending_sync should be set
        assert.is_equal(1, push_called)
        assert.is_true(sync_instance.manager.has_pending_sync)

        -- Now trigger the first sync's callback.
        -- This should complete the first sync and immediately trigger the pending sync on nextTick
        cb_trigger(true)
        fastforward_ui_events() -- Runs nextTick and schedules push_progress_bg
        fastforward_ui_events() -- Runs 0.1s schedule
        assert.is_equal(2, push_called)
        assert.is_false(sync_instance.manager.has_pending_sync)

        remote.push_progress_bg = old_push
    end)

    it("flushes pending sync immediately on onCloseDocument or onSuspend", function()
        local remote = require("remote")
        local push_called = 0
        local old_push = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback)
            push_called = push_called + 1
            callback(true)
        end

        -- Page 1 -> 2: triggers interval (interval = 2)
        readerui.document.page = 1
        sync_instance:onPageUpdate()
        readerui.document.page = 2
        sync_instance:onPageUpdate()

        -- Should not be pushed immediately
        assert.is_equal(0, push_called)

        -- Call onCloseDocument
        sync_instance:onCloseDocument()
        fastforward_ui_events()

        assert.is_equal(1, push_called)

        -- Reset for onSuspend
        sync_instance.manager.page_turn_counter = 0
        readerui.document.page = 3
        sync_instance:onPageUpdate()
        readerui.document.page = 4
        sync_instance:onPageUpdate()

        assert.is_equal(1, push_called)

        -- Call onSuspend
        sync_instance:onSuspend()
        fastforward_ui_events()

        assert.is_equal(2, push_called)

        remote.push_progress_bg = old_push
    end)
end)
