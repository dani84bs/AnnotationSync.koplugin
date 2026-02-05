local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local SyncService = require("apps/cloudstorage/syncservice")
local _ = require("gettext")

local annotations = require("annotations")

local M = {}

function M.sync_annotations(widget, document, json_path, on_complete, force)
    local server_json = G_reader_settings:readSetting("cloud_server_object")
    if server_json and server_json ~= "" then
        local server = json.decode(server_json)
        SyncService.sync(server, json_path, function(local_file, cached_file, income_file)
            local success, merged_list = annotations.sync_callback(document, local_file, cached_file, income_file, force)
            if on_complete then
                on_complete(success, merged_list)
            end
            return success
        end, false)
    else
        UIManager:show(InfoMessage:new {
            text = T(_("No cloud destination set in settings.")),
            timeout = 4
        })
        if on_complete then
            on_complete(false)
        end
    end
end

function M.save_server_settings(server)
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    if server.type then
        G_reader_settings:saveSetting("cloud_provider_type", server.type)
    end
    UIManager:show(InfoMessage:new {
        text = T(_("Cloud destination set to:\n%1\nProvider: %2\nPlease restart KOReader for changes to take effect."),
            server.url, server.type or "unknown"),
        timeout = 4
    })
    UIManager:close()
end

return M
