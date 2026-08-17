local DataStorage = require("datastorage")
local util = require("util")
local logger = require("logger")
local json = require("json")
local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")

local utils = require("utils")
local remote = require("remote")
local settings_domain = require("settings_domain")
local excluded_settings = require("excluded_settings")

local M = {}

function M.get_selected_with_values(plugin)
    local selected = plugin.settings.selected_settings or {}
    local has_any = false
    for _, _ in pairs(selected) do
        has_any = true
        break
    end
    if not has_any then
        return nil
    end

    local caches = {}
    local result = {}
    for key, is_selected in pairs(selected) do
        if is_selected and not excluded_settings.is_key_excluded(key) then
            local domain, full_key = settings_domain.parse(key)
            if domain and full_key then
                result[key] = settings_domain.get_value(domain, full_key, caches)
            end
        end
    end

    return result
end

function M.push(plugin)
    local selected_values = M.get_selected_with_values(plugin)
    if not selected_values then
        utils.show_msg(_("No settings are selected. Please select settings to sync in 'Show changed settings'."))
        return
    end

    local device_id = utils.get_device_name(plugin)
    local local_data = {
        [device_id] = {
            settings = selected_values,
            timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        }
    }

    local json_path = DataStorage:getDataDir() .. "/settings_sync.json"
    local ok, err = util.writeToFile(json.encode(local_data), json_path, true, false, true)
    if not ok then
        logger.warn("AnnotationSync: failed to write settings JSON: " .. json_path .. " (" .. tostring(err) .. ")")
        utils.show_msg(_("Failed to write settings to local storage."))
        return
    end

    logger.dbg("AnnotationSync: pushing settings to remote: " .. json_path)
    utils.show_msg(_("Pushing settings to cloud..."))
    remote.sync_settings(plugin, json_path, function(success)
        if success then
            logger.dbg("AnnotationSync: settings push successful")
        else
            logger.warn("AnnotationSync: settings push failed")
        end
    end)
end

function M.values_differ(v1, v2)
    if type(v1) ~= type(v2) then
        return true
    end
    if type(v1) == "table" then
        return json.encode(v1) ~= json.encode(v2)
    end
    return v1 ~= v2
end

function M.get_local_value(key, caches)
    local domain, full_key = settings_domain.parse(key)
    if not domain or not full_key then return nil end
    return settings_domain.get_value(domain, full_key, caches)
end

function M.write_local_value(key, value)
    local domain, full_key = settings_domain.parse(key)
    if not domain or not full_key then return false end
    return settings_domain.write_value(domain, full_key, value)
end

function M.pull(plugin)
    if not NetworkMgr:isConnected() then
        utils.show_msg(_("Network is disconnected, cannot pull settings"))
        return
    end

    local json_path = DataStorage:getDataDir() .. "/settings_sync.json"

    utils.show_msg(_("Fetching settings from cloud..."))
    remote.sync_settings(plugin, json_path, function(success, merged_data)
        if success and merged_data then
            local menus = require("menus")
            menus.show_devices_menu(plugin, merged_data)
        else
            utils.show_msg(_("Failed to fetch settings from cloud"))
        end
    end)
end

return M
