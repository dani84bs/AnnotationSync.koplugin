local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local AnnotationSyncPlugin = WidgetContainer:extend{
    name = "AnnotationSync"
}

local filemanager_order = require("ui/elements/filemanager_menu_order")
local reader_order = require("ui/elements/reader_menu_order")

local utils = require("plugins/AnnotationSync.koplugin/utils")
utils.insert_after_statistics(filemanager_order, "annotation_sync_plugin")
utils.insert_after_statistics(reader_order, "annotation_sync_plugin")

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = "tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Sync annotations between devices."),
                timeout = 2
            })
        end
    }
end

return AnnotationSyncPlugin
