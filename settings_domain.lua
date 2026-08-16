local DataStorage = require("datastorage")
local util = require("util")
local utils = require("utils")

local M = {}

function M.parse(key)
    return key:match("^([^:]+):(.*)$")
end

function M.active_path(domain)
    if domain == "reader" then
        return DataStorage:getDataDir() .. "/settings.reader.lua"
    elseif domain == "defaults" then
        return DataStorage:getDataDir() .. "/defaults.custom.lua"
    elseif domain:match("^settings/") then
        local settings_name = domain:sub(10)
        return DataStorage:getSettingsDir() .. "/" .. settings_name .. ".lua"
    end
    return nil
end

-- Reads the active value for domain:full_key, caching the dofile'd table per domain in `caches`
function M.get_value(domain, full_key, caches)
    caches = caches or {}
    if caches[domain] == nil then
        local filepath = M.active_path(domain)
        if not filepath then
            caches[domain] = false
        else
            local ok, tbl = pcall(dofile, filepath)
            caches[domain] = (ok and type(tbl) == "table") and tbl or false
        end
    end
    local tbl = caches[domain]
    if not tbl then return nil end
    return utils.get_nested_value(tbl, full_key)
end

local function save_nested_setting(settings_obj, parts, value)
    if #parts == 1 then
        settings_obj:saveSetting(parts[1], value)
    else
        local top_key = parts[1]
        local top_val = settings_obj:readSetting(top_key)
        if type(top_val) ~= "table" then
            top_val = {}
        end
        local new_tbl = util.tableDeepCopy(top_val)
        local current = new_tbl
        for i = 2, #parts - 1 do
            local part = parts[i]
            if type(current[part]) ~= "table" then
                current[part] = {}
            end
            current = current[part]
        end
        current[parts[#parts]] = value
        settings_obj:saveSetting(top_key, new_tbl)
    end
    settings_obj:flush()
end

-- Writes domain:full_key = value to the active settings file (and, for
-- "reader", to the live G_reader_settings object too)
function M.write_value(domain, full_key, value)
    local filepath = M.active_path(domain)
    if not filepath then return false end

    local LuaSettings = require("luasettings")
    local parts = {}
    for part in string.gmatch(full_key, "([^%.]+)") do
        table.insert(parts, part)
    end

    if domain == "reader" then
        save_nested_setting(G_reader_settings, parts, value)
    end

    local settings_obj = LuaSettings:open(filepath)
    save_nested_setting(settings_obj, parts, value)
    return true
end

return M
