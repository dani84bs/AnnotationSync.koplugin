local _ = function(s) return s end

describe("SyncService Silent Mode Repro", function()
    local UIManager, NetworkMgr, remote
    local test_data_dir = os.getenv("PWD") .. "/test_sync_service_repro_tmp"

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        UIManager = require("ui/uimanager")
        NetworkMgr = require("ui/network/manager")
        remote = require("remote")
        
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

        -- Mock sync callback
        local sync_cb = function() return true end

        -- Create a dummy file
        local test_file = test_data_dir .. "/test.json"
        os.execute("mkdir -p " .. test_data_dir)
        local f = io.open(test_file, "w")
        f:write("{}")
        f:close()

        -- Mock cloudstorage plugin
        local mock_widget = {
            ui = {
                cloudstorage = {
                    sync = function(self, server, file_path, sync_cb, is_silent)
                        -- Simulate successful sync notification
                        UIManager:show(require("ui/widget/notification"):new{
                            text = _("Successfully synchronized."),
                            timeout = 2,
                        })
                        local success = sync_cb(file_path, file_path, file_path)
                        return success
                    end
                }
            },
            settings = {
                sync_server = { url = "/test" }
            }
        }

        remote.push_progress(mock_widget, test_file, sync_cb)

        UIManager.show = old_show
        os.execute("rm -rf " .. test_data_dir)

        assert.is_false(show_called, "UIManager:show was called even though is_silent was true")
    end)
end)
