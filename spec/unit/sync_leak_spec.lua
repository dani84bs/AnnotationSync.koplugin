local test_data_dir = os.getenv("PWD") .. "/test_sync_leak_tmp"
os.execute("mkdir -p " .. test_data_dir .. "/cache")

-- Fix for DocCache requiring G_defaults and DataStorage during module load
_G.G_defaults = {
    rw = function() return {} end
}
local DataStorage = {
    getDataDir = function() return test_data_dir end,
    getHistoryDir = function() return test_data_dir end,
    getSettingsDir = function() return test_data_dir end,
}
setmetatable(DataStorage, {
    __index = function(t, k)
        if k:match("^get") then
            return function() return test_data_dir end
        end
    end
})
package.loaded["datastorage"] = DataStorage

require("commonrequire")

local DocumentRegistry = require("document/documentregistry")
local SyncService = require("apps/cloudstorage/syncservice")

describe("Sync Document Leak Verification", function()
    local manager
    local test_utils
    local old_getDataDir
    local open_calls = {}
    local close_calls = {}

    setup(function()
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        
        test_utils = require("spec/unit/test_utils")
        local SyncManager = require("manager")
        
        -- Mock Plugin object
        local mock_plugin = {
            ui = {
                document = { file = "spec/front/unit/data/juliet.epub" }
            },
            settings = {
                use_filename = true
            }
        }
        
        manager = SyncManager:new(mock_plugin)
        
        disable_plugins()
        old_getDataDir = test_utils.setup_test_env(test_data_dir)
        
        -- Mock DocumentRegistry:getProvider
        DocumentRegistry.getProvider = function()
            return { provider = "crengine" }
        end

        -- Mock DocumentRegistry:openDocument
        local old_open = DocumentRegistry.openDocument
        DocumentRegistry.openDocument = function(self, file, provider)
            open_calls[file] = (open_calls[file] or 0) + 1
            return {
                file = file,
                info = {},
                close = function(doc)
                    close_calls[file] = (close_calls[file] or 0) + 1
                end,
                getAnnotations = function() return {} end,
                saveAnnotations = function() end,
                getProps = function() return {} end,
                render = function() end,
            }
        end
        _G.old_DocumentRegistry_open = old_open

        test_utils.mock_sync_service(SyncService)
        
        -- Mock SyncManager functions that might rely on UI or other complex stuff
        manager.getAnnotationsForDocument = function() return {} end
        -- SyncManager:writeAnnotationsJSON uses docsettings and annotations
        package.loaded["docsettings"] = {
            getSidecarDir = function() return test_data_dir end
        }
        package.loaded["annotations"] = {
            write_annotations_json = function(_, _, sdr_dir, filename)
                return sdr_dir .. "/" .. filename
            end,
            sync_callback = function() return true, {} end
        }
        -- remote.sync_annotations is also needed
        package.loaded["remote"] = {
            sync_annotations = function(plugin, document, json_path, on_complete, force)
                on_complete(true, {})
            end
        }
    end)

    teardown(function()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        DocumentRegistry.openDocument = _G.old_DocumentRegistry_open
        package.loaded["manager"] = nil
    end)

    before_each(function()
        open_calls = {}
        close_calls = {}
        -- Clear changed documents
        local f = io.open(manager:changedDocumentsFile(), "w")
        f:write("return {}")
        f:close()
    end)

    it("closes document handles after syncing multiple documents", function()
        local doc1 = "spec/front/unit/data/juliet.epub" -- Current UI document
        local doc2 = "spec/front/unit/data/leaves.epub"
        local doc3 = "spec/front/unit/data/mock.pdf"

        -- Add to changed documents
        manager:addToChangedDocumentsFile(doc1)
        manager:addToChangedDocumentsFile(doc2)
        manager:addToChangedDocumentsFile(doc3)

        -- Execute Sync All
        manager:syncAllChangedDocuments()

        -- Diagnostics
        print("\n--- Sync Leak Diagnostics ---")
        for f, count in pairs(open_calls) do
            print(string.format("File: %s | Opened: %d | Closed: %d", f, count, close_calls[f] or 0))
        end

        -- Assertions
        -- doc1 is UI document, should NOT be closed (UI still uses it)
        assert.is_nil(close_calls[doc1], "UI document should NOT have been closed")
        
        -- For doc2 and doc3, they should be opened AND closed.
        assert.is_equal(1, close_calls[doc2], "doc2 should have been closed")
        assert.is_equal(1, close_calls[doc3], "doc3 should have been closed")
        
        assert.is_equal(1, open_calls[doc2], "doc2 should have been opened once")
        assert.is_equal(1, open_calls[doc3], "doc3 should have been opened once")
    end)

    it("closes document handles even if sync fails (pcall verification)", function()
        local doc_fail = "spec/front/unit/data/fail.epub"
        manager:addToChangedDocumentsFile(doc_fail)

        -- Mock syncDocument to crash or fail
        local old_syncDoc = manager.syncDocument
        manager.syncDocument = function() error("Simulated sync crash") end

        manager:syncAllChangedDocuments()

        -- Restore
        manager.syncDocument = old_syncDoc

        assert.is_equal(1, open_calls[doc_fail], "fail.epub should have been opened")
        assert.is_equal(1, close_calls[doc_fail], "fail.epub should have been closed despite crash")
    end)
end)
