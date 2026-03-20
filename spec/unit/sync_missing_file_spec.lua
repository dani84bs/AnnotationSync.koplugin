local test_data_dir = os.getenv("PWD") .. "/test_sync_missing_tmp"
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

-- Mock modules before requiring manager
local util = require("util")
local existing_files = {}
_G.old_util_fileExists = util.fileExists
util.fileExists = function(file)
    return existing_files[file] == true
end

package.loaded["remote"] = {
    sync_annotations = function(plugin, document, json_path, on_complete, force)
        on_complete(true, {})
    end
}

package.loaded["annotations"] = {
    write_annotations_json = function(_, _, sdr_dir, filename)
        return sdr_dir .. "/" .. filename
    end,
    get_annotations = function() return {} end
}

package.loaded["docsettings"] = {
    getSidecarDir = function() return test_data_dir end
}

local DocumentRegistry = require("document/documentregistry")
local open_calls = {}
local close_calls = {}

local old_open = DocumentRegistry.openDocument
DocumentRegistry.openDocument = function(self, file, provider)
    if not existing_files[file] then
        return nil
    end
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

local old_getProvider = DocumentRegistry.getProvider
DocumentRegistry.getProvider = function(self, file)
    if existing_files[file] then
        return { provider = "crengine" }
    end
    return nil
end

local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
package.path = plugin_path .. ";" .. package.path
local SyncManager = require("manager")

describe("Sync Missing File Handling", function()
    local manager
    local test_utils
    local old_getDataDir

    setup(function()
        test_utils = require("spec/unit/test_utils")
        
        -- Mock Plugin object
        local mock_plugin = {
            ui = {
                document = { file = "spec/front/unit/data/juliet.epub" }
            },
            settings = {
                use_filename = true
            },
            applySyncedAnnotations = function() end
        }
        
        manager = SyncManager:new(mock_plugin)
        manager.getAnnotationsForDocument = function() return {} end
        
        disable_plugins()
        old_getDataDir = test_utils.setup_test_env(test_data_dir)
    end)

    teardown(function()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        DocumentRegistry.openDocument = old_open
        DocumentRegistry.getProvider = old_getProvider
        util.fileExists = _G.old_util_fileExists
        package.loaded["manager"] = nil
        package.loaded["remote"] = nil
        package.loaded["annotations"] = nil
        package.loaded["docsettings"] = nil
    end)

    before_each(function()
        for k, v in pairs(open_calls) do open_calls[k] = nil end
        for k, v in pairs(close_calls) do close_calls[k] = nil end
        for k, v in pairs(existing_files) do existing_files[k] = nil end
        -- Clear changed documents
        local f = io.open(manager:changedDocumentsFile(), "w")
        f:write("return {}")
        f:close()
    end)

    it("handles missing files during Sync All gracefully", function()
        local doc1 = "spec/front/unit/data/other.epub" -- NOT the UI document
        local doc2 = "spec/front/unit/data/missing.epub" -- Missing file

        existing_files[doc1] = true
        existing_files[doc2] = false -- Explicitly missing

        -- Add to changed documents
        manager:addToChangedDocumentsFile(doc1)
        manager:addToChangedDocumentsFile(doc2)

        -- Execute Sync All
        manager:syncAllChangedDocuments()

        -- Assertions
        assert.is_equal(1, open_calls[doc1], "doc1 should have been opened")
        assert.is_equal(1, close_calls[doc1], "doc1 should have been closed")
        assert.is_nil(open_calls[doc2], "doc2 should NOT have been opened")
        
        -- Check if doc2 was removed from dirty list
        local _, changed_docs_after = manager:getPendingChangedDocuments()
        assert.is_nil(changed_docs_after[doc2], "doc2 should have been removed from the dirty list")
        assert.is_nil(changed_docs_after[doc1], "doc1 should have been removed after successful sync")
    end)
end)
