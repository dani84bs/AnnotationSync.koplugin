describe("SyncService Silent Mode Repro", function()
    local UIManager, SyncService, NetworkMgr
    local test_data_dir = os.getenv("PWD") .. "/test_sync_service_repro_tmp"

    setup(function()
        require("commonrequire")
        UIManager = require("ui/uimanager")
        SyncService = require("apps/cloudstorage/syncservice")
        NetworkMgr = require("ui/network/manager")
        
        -- Mock Network connected
        NetworkMgr.isConnected = function() return true end
        NetworkMgr.willRerunWhenConnected = function() return false end
        NetworkMgr.willRerunWhenOnline = function() return false end
    end)

    it("should NOT call UIManager:show on success when is_silent is true", function()
        local show_called = false
        local old_show = UIManager.show
        UIManager.show = function(this, widget)
            show_called = true
        end

        -- Mock server and API
        local server = { type = "webdav", url = "/test", address = "http://localhost", username = "u", password = "p" }
        local webdavapi = require("apps/cloudstorage/webdavapi")
        webdavapi.downloadFile = function() return 200, "etag123" end
        webdavapi.uploadFile = function() return 201 end
        webdavapi.getJoinedPath = function(_, a, b) return a .. b end

        -- Mock sync callback
        local sync_cb = function() return true end

        -- Create a dummy file
        local test_file = test_data_dir .. "/test.json"
        os.execute("mkdir -p " .. test_data_dir)
        local f = io.open(test_file, "w")
        f:write("{}")
        f:close()

        SyncService.sync(server, test_file, sync_cb, true)

        UIManager.show = old_show
        os.execute("rm -rf " .. test_data_dir)

        assert.is_false(show_called, "UIManager:show was called even though is_silent was true")
    end)
end)
