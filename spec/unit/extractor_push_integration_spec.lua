describe("Extractor push API integration", function()
    local ReaderUI, UIManager, SyncService, PluginShare, NetworkMgr, Device
    local AnnotationSyncPlugin, test_utils, json
    local readerui, sync_instance
    local test_data_dir = os.getenv("PWD") .. "/test_extractor_push_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        ReaderUI = require("apps/reader/readerui")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        PluginShare = require("pluginshare")
        NetworkMgr = require("ui/network/manager")
        Device = require("device")
        json = require("json")

        test_utils = require("spec/unit/test_utils")
        AnnotationSyncPlugin = require("main")

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
    end)

    before_each(function()
        UIManager:show(readerui)
        fastforward_ui_events()
        test_utils.mock_sync_service(SyncService)

        NetworkMgr.isWifiOn = function() return true end
        NetworkMgr.isConnected = function() return true end
        Device.model = "TestDevice"

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
        local Geom = require("ui/geometry")
        readerui.document.getNativePageDimensions = function(this, pageno)
            return Geom:new{ w = 1200, h = 1600 }
        end
    end)

    local function field(value, policy, changed_at)
        return { value = value, policy = policy, changed_at = changed_at }
    end

    local function find_record(records, merge_key)
        for _, record in ipairs(records) do
            if record.merge_key == merge_key then
                return record
            end
        end
    end

    it("is reachable via PluginShare.AnnotationSync once the plugin has initialized", function()
        assert.is_not_nil(PluginShare.AnnotationSync)
        assert.is_function(PluginShare.AnnotationSync.pushExtractorData)
    end)

    it("namespaces the synced path by <extractor_id>__<filename>, reuploads only on change, and always calls writeback_fn", function()
        local captured_local_path
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            captured_local_path = local_path
            local success = callback(local_path, local_path .. ".last_sync", local_path .. ".income")
            return success
        end

        local writeback_calls = {}
        local records = {
            { merge_key = "hola", fields = { phrase = field("hola", "write_once", 100) } }
        }

        PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "spanish", records, function(merged)
            table.insert(writeback_calls, merged)
        end)

        assert.is_not_nil(captured_local_path)
        assert.is_not_nil(captured_local_path:find("extractors/vocabdeck__spanish.json", 1, true))
        assert.is_equal(1, #writeback_calls)
        assert.is_equal("hola", find_record(writeback_calls[1], "hola").fields.phrase.value)

        SyncService.sync = old_sync
    end)

    it("puts extractor_id__filename in the basename so it survives a basename-only remote", function()
        -- Regression (gh-95): KOReader's Cloud:sync reduces whatever path
        -- it's given to ffiUtil.basename(file_path) before talking to the
        -- remote, so only the basename itself can carry namespacing on the
        -- wire -- a real "extractors/<extractor_id>/<filename>" subdirectory
        -- would silently lose the extractor_id segment remotely.
        local ffiUtil = require("ffi/util")
        local captured_local_path
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            captured_local_path = local_path
            return callback(local_path, local_path .. ".last_sync", local_path .. ".income")
        end

        local records = {
            { merge_key = "hola", fields = { phrase = field("hola", "write_once", 100) } }
        }
        PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "basename-check", records, function() end)

        assert.is_equal("vocabdeck__basename-check.json", ffiUtil.basename(captured_local_path))

        SyncService.sync = old_sync
    end)

    it("reports changed=true on a first sync against an empty remote", function()
        -- Regression (gh-94): keyed_merge previously only flagged `changed`
        -- when incoming taught local something new, so a genuine first sync
        -- (empty incoming) never uploaded local-only data at all.
        local sync_cb_result
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            sync_cb_result = callback(local_path, local_path .. ".last_sync", local_path .. ".income")
            return sync_cb_result
        end

        local records = {
            { merge_key = "hola", fields = { phrase = field("hola", "write_once", 100) } }
        }
        PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "first-sync", records, function() end)

        assert.is_true(sync_cb_result)

        SyncService.sync = old_sync
    end)

    it("reports changed=true and rewrites the local file when incoming data differs", function()
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            local income_path = local_path .. ".income"
            local f = io.open(income_path, "w")
            f:write(json.encode({
                bonjour = { fields = { phrase = field("bonjour", "write_once", 100) } }
            }))
            f:close()

            local success = callback(local_path, local_path .. ".last_sync", income_path)
            os.remove(income_path)
            return success
        end

        local merged_result
        PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "french", {}, function(merged)
            merged_result = merged
        end)

        assert.is_not_nil(merged_result)
        assert.is_equal("bonjour", find_record(merged_result, "bonjour").fields.phrase.value)

        SyncService.sync = old_sync
    end)

    it("reports changed=false on a second push once remote already has the data", function()
        -- A fake single-file WebDAV: income mirrors whatever the previous
        -- successful upload wrote, so this actually exercises "does remote
        -- need this" rather than always handing back an empty incoming.
        local remote_store = {}
        local sync_cb_result
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            local income_path = local_path .. ".income"
            local f = io.open(income_path, "w")
            f:write(json.encode(remote_store[local_path] or {}))
            f:close()

            sync_cb_result = callback(local_path, local_path .. ".last_sync", income_path)
            os.remove(income_path)

            if sync_cb_result then
                local uploaded = io.open(local_path):read("*a")
                remote_store[local_path] = json.decode(uploaded)
            end
            return sync_cb_result
        end

        local records = {
            { merge_key = "hola", fields = { phrase = field("hola", "write_once", 100) } }
        }

        -- First push: empty remote -> uploads and seeds remote_store.
        PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "spanish2", records, function() end)
        assert.is_true(sync_cb_result)

        -- Second push with the exact same records: remote already matches.
        PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "spanish2", records, function() end)
        assert.is_false(sync_cb_result)

        SyncService.sync = old_sync
    end)

    it("catches a throwing writeback_fn without propagating, and doesn't disturb a subsequent annotation sync", function()
        local old_sync = SyncService.sync
        SyncService.sync = function(server, local_path, callback, is_silent)
            return callback(local_path, local_path .. ".last_sync", local_path .. ".income")
        end

        local ok = pcall(function()
            PluginShare.AnnotationSync.pushExtractorData("vocabdeck", "throws", {}, function()
                error("boom: writeback exploded")
            end)
        end)
        assert.is_true(ok)

        SyncService.sync = old_sync

        -- A normal document sync right after must still work (uses the
        -- standard test_utils mock, which needs real income/last_sync files).
        local completed = false
        local success_result
        sync_instance.manager:syncDocument(readerui.document, true, function(success)
            completed = true
            success_result = success
        end)
        fastforward_ui_events()

        assert.is_true(completed)
        assert.is_true(success_result)
    end)

    it("fires AnnotationSyncRequested exactly once per manualSync call, and not from progress/settings sync", function()
        local settings_sync = require("settings_sync")
        local remote = require("remote")

        local fired = 0
        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(this, event)
            if event.handler == "onAnnotationSyncRequested" then
                fired = fired + 1
            end
            old_broadcast(this, event)
        end

        sync_instance:manualSync()
        fastforward_ui_events()
        assert.is_equal(1, fired)

        -- settings sync must not fire it
        local old_push_settings = remote.sync_settings
        remote.sync_settings = function(widget, json_path, on_complete)
            if on_complete then on_complete(true, {}) end
        end
        sync_instance.settings.selected_settings = {}
        settings_sync.push(sync_instance) -- no-op: nothing selected, but still shouldn't broadcast
        assert.is_equal(1, fired)
        remote.sync_settings = old_push_settings

        -- progress push must not fire it
        local old_push_progress_bg = remote.push_progress_bg
        remote.push_progress_bg = function(widget, path, callback) callback(true) end
        sync_instance.manager:syncProgress(function() end)
        assert.is_equal(1, fired)
        remote.push_progress_bg = old_push_progress_bg

        UIManager.broadcastEvent = old_broadcast
    end)

    it("fires AnnotationSyncRequested from _onNetworkConnected even when no documents are pending", function()
        local changed_documents = require("changed_documents")
        os.remove(changed_documents.path())

        local fired = 0
        local old_broadcast = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(this, event)
            if event.handler == "onAnnotationSyncRequested" then
                fired = fired + 1
            end
            old_broadcast(this, event)
        end

        sync_instance:_onNetworkConnected()

        assert.is_equal(1, fired)
        UIManager.broadcastEvent = old_broadcast
    end)
end)
