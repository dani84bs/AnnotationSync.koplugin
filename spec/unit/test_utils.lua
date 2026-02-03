local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local Geom = require("ui/geometry")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local ImageViewer = require("ui/widget/imageviewer")
local json = require("json")

local M = {}

function M.setup_test_env(test_data_dir)
    os.execute("mkdir -p " .. test_data_dir .. "/cache")
    local old_getDataDir = DataStorage.getDataDir
    DataStorage.getDataDir = function() return test_data_dir end
    return old_getDataDir
end

function M.teardown_test_env(test_data_dir, old_getDataDir)
    DataStorage.getDataDir = old_getDataDir
    os.execute("rm -rf " .. test_data_dir)
end

function M.mock_image_viewer()
    local old_new = ImageViewer.new
    ImageViewer.new = function(this, o)
        local mock = setmetatable(o or {}, { __index = ImageViewer })
        mock.update = function() end
        mock.onShow = function() end
        mock.paintTo = function() end
        return mock
    end
    return old_new
end

function M.init_integration_context(file, AnnotationSyncPlugin)
    local readerui = ReaderUI:new{
        dimen = Geom:new{ w = 1200, h = 1600 },
        document = DocumentRegistry:openDocument(file),
    }
    
    local sync_instance = AnnotationSyncPlugin:new{ 
        ui = readerui, 
        plugin_id = "AnnotationSync",
        version = "test"
    }
    
    -- In a real scenario, PluginLoader calls init.
    local old_register = readerui.menu.registerToMainMenu
    readerui.menu.registerToMainMenu = function() end
    sync_instance:init()
    readerui.menu.registerToMainMenu = old_register
    
    -- Hook the plugin into readerui to receive events
    table.insert(readerui, sync_instance)
    UIManager:show(readerui)
    
    return readerui, sync_instance
end

function M.emulate_highlight(readerui, entry)
    local pos0 = Geom:new(entry.pos0)
    local pos1 = Geom:new(entry.pos1)
    
    readerui.highlight:onHold(nil, { pos = pos0 })
    readerui.highlight:onHoldPan(nil, { pos = pos1 })
    readerui.highlight:onHoldRelease()
    fastforward_ui_events()
    
    return readerui.highlight:saveHighlight()
end

function M.mock_sync_service(SyncService)
    local old_sync = SyncService.sync
    SyncService.sync = function(server, local_path, callback, upload_only)
        local ok, result = pcall(callback, local_path, local_path, local_path)
        if not ok then
            error("Sync callback CRASHED: " .. tostring(result))
        end
        if not result then
            error("Sync callback contract violation: function returned nil/false instead of true. " ..
                  "This triggers 'Something went wrong' in production.")
        end
    end
    return old_sync
end

function M.write_mock_json(test_data_dir, filename, data)
    local path = test_data_dir .. "/" .. filename
    local f = io.open(path, "w")
    f:write(json.encode(data))
    f:close()
    return path
end

return M
