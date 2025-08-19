local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local T = require("ffi/util").template

local AnnotationSyncPlugin = WidgetContainer:extend{
    name = "AnnotationSync"
}

local filemanager_order = require("ui/elements/filemanager_menu_order")
local reader_order = require("ui/elements/reader_menu_order")

local utils = require("utils")
utils.insert_after_statistics(filemanager_order, "annotation_sync_plugin")
utils.insert_after_statistics(reader_order, "annotation_sync_plugin")

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = "tools",
        sub_item_table = {{
            text = _("Settings"),
            callback = function()
                local plugin = self
                local SyncService = require("apps/cloudstorage/syncservice")
                local sync_service = SyncService:new{}
                sync_service.onConfirm = function(server)
                    -- Save the chosen cloud directory path to settings
                    G_reader_settings:saveSetting("cloud_download_dir", server.url)
                    UIManager:show(InfoMessage:new{
                        text = T(_(
                            "Cloud download directory set to:\n%1\nPlease restart KOReader for changes to take effect."),
                            server.url),
                        timeout = 4
                    })
                    UIManager:close()
                    if plugin and plugin.ui and plugin.ui.menu and plugin.ui.menu.showMainMenu then
                        plugin.ui.menu:showMainMenu()
                    end
                end
                UIManager:show(sync_service)
            end
        }, {
            text = _("Manual Sync"),
            enabled = (G_reader_settings:readSetting("cloud_download_dir") or "") ~= "",
            callback = function()
                local dir = G_reader_settings:readSetting("cloud_download_dir")
                local msg
                if dir and dir ~= "" then
                    msg = T(_("Current cloud directory:\n%1"), dir)
                else
                    msg = _("No cloud directory selected.")
                end
                UIManager:show(InfoMessage:new{
                    text = msg,
                    timeout = 3
                })
            end
        }}
    }
end

return AnnotationSyncPlugin
