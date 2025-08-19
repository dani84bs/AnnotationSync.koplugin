local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

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
                UIManager:show(InfoMessage:new{
                    text = _("Settings stub - not yet implemented."),
                    timeout = 2
                })
            end
        }, {
            text = _("Manual Sync"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Manual Sync stub - not yet implemented."),
                    timeout = 2
                })
            end
        }}
    }
end

return AnnotationSyncPlugin
