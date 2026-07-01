local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local PathChooser = require("ui/widget/pathchooser")
local _ = require("gettext")

local M = {}

local function strip_trailing_slash(path)
    if path ~= "/" then
        path = path:gsub("/+$", "")
    end
    return path
end

function M.show(plugin)
    plugin.settings.progress_sync_excluded_dirs = plugin.settings.progress_sync_excluded_dirs or {}
    local menu

    local function refresh()
        if menu then UIManager:close(menu) end
        M.show(plugin)
    end

    local menu_items = {}

    table.insert(menu_items, {
        text = _("Add directory..."),
        bold = true,
        callback = function()
            local path_chooser = PathChooser:new{
                path = G_reader_settings:readSetting("home_dir") or "/",
                select_file = false,
                onConfirm = function(folder)
                    folder = strip_trailing_slash(folder)
                    table.insert(plugin.settings.progress_sync_excluded_dirs, folder)
                    plugin:saveSettings()
                    refresh()
                end,
            }
            UIManager:show(path_chooser)
        end,
        separator = true,
    })

    local excluded_dirs = plugin.settings.progress_sync_excluded_dirs
    if #excluded_dirs == 0 then
        table.insert(menu_items, {
            text = _("No directories excluded"),
            enabled = false,
        })
    else
        for i, dir in ipairs(excluded_dirs) do
            table.insert(menu_items, {
                text = dir,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove this directory from the exclude list?") .. "\n\n" .. dir,
                        ok_text = _("Remove"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            table.remove(plugin.settings.progress_sync_excluded_dirs, i)
                            plugin:saveSettings()
                            refresh()
                        end,
                    })
                end,
            })
        end
    end

    menu = Menu:new{
        title = _("Excluded directories for progress sync"),
        item_table = menu_items,
    }
    UIManager:show(menu)
end

return M
