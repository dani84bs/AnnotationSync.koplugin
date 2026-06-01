local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local Geom = require("ui/geometry")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local ImageViewer = require("ui/widget/imageviewer")
local json = require("json")

local M = {}

local current_readerui

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
    current_readerui = readerui
    
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
    
    -- Ensure sync_server is populated for tests using legacy cloud_server_object
    -- Use a metatable to handle cases where cloud_server_object is set AFTER init
    if sync_instance.settings then
        setmetatable(sync_instance.settings, {
            __index = function(t, k)
                if k == "sync_server" then
                    local server_json = G_reader_settings:readSetting("cloud_server_object")
                    if server_json and server_json ~= "" then
                        local ok, server = pcall(json.decode, server_json)
                        if ok and server then
                            rawset(t, "sync_server", server)
                            return server
                        end
                    end
                end
                return nil
            end
        })
    end

    -- Automatically mock cloudstorage if SyncService is available
    local ok, SyncService = pcall(require, "apps/cloudstorage/syncservice")
    if ok then
        M.mock_sync_service(SyncService)
    end

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
        -- Robustness: ensure we have valid paths and files
        local test_data_dir = DataStorage.getDataDir()
        local function ensure_json_file(path)
            if not path or type(path) ~= "string" then
                return nil
            end
            local f = io.open(path, "r")
            local content = f and f:read("*a")
            if f then f:close() end
            
            -- If file doesn't exist, is empty, or doesn't start with '{', make it a valid empty JSON object
            if not content or content == "" or content:sub(1,1) ~= "{" then
                -- Ensure directory exists
                local dir = path:match("(.*)/")
                if dir then
                    os.execute("mkdir -p " .. dir)
                end
                local fw = io.open(path, "w")
                if not fw then
                    -- Fallback to test_data_dir if original path is not writable
                    local filename = path:match("([^/]+)$") or "unknown.json"
                    path = test_data_dir .. "/" .. filename
                    fw = io.open(path, "w")
                end
                if fw then
                    fw:write("{}")
                    fw:close()
                else
                    return nil
                end
            end
            return path
        end

        -- Ensure we have a valid local path, fallback to dummy if needed
        local actual_local = ensure_json_file(local_path) or (test_data_dir .. "/dummy_local.json")
        ensure_json_file(actual_local)

        -- Use separate files for last_sync and income to avoid conflicts
        -- and ensure they are valid JSON.
        local last_sync_file = ensure_json_file(actual_local .. ".last_sync") or (test_data_dir .. "/dummy_last.json")
        ensure_json_file(last_sync_file)

        local income_file = ensure_json_file(actual_local .. ".income") or (test_data_dir .. "/dummy_income.json")
        ensure_json_file(income_file)

        local ok, result = pcall(callback, actual_local, last_sync_file, income_file)
        if not ok then
            error("Sync callback CRASHED: " .. tostring(result))
        end
        if not result then
            error("Sync callback contract violation: function returned nil/false instead of true. " ..
                  "This triggers 'Something went wrong' in production.")
        end
        return result
    end

    if current_readerui then
        if not current_readerui.cloudstorage then
            current_readerui.cloudstorage = {}
        end
        current_readerui.cloudstorage.sync = function(self, server, file_path, sync_cb, is_silent, caller_pre_callback)
            return SyncService.sync(server, file_path, sync_cb)
        end
    end

    return old_sync
end

function M.write_mock_json(test_data_dir, filename, data)
    local path = test_data_dir .. "/" .. filename
    local f = io.open(path, "w")
    local encoded = json.encode(data)
    -- KOReader's isPossiblyJson only accepts '{', but json.encode({}) might be '[]'
    if encoded == "[]" then encoded = "{}" end
    f:write(encoded)
    f:close()
    return path
end

return M
