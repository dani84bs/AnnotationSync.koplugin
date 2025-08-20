local json = require("json")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

function M.save_server_settings(server)
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    if server.type then
        G_reader_settings:saveSetting("cloud_provider_type", server.type)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Cloud destination set to:\n%1\nProvider: %2\nPlease restart KOReader for changes to take effect."),
            server.url, server.type or "unknown"),
        timeout = 4
    })
    UIManager:close()
end

return M
