local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local Event = require("ui/event")
local _ = require("gettext")
local T = require("ffi/util").template
local utils = require("utils")
local annotations = require("annotations")

local M = {}

function M.show_deleted_annotations(plugin, document)
    if not document then return end

    local deleted = plugin.manager:getDeletedAnnotations(document)
    if #deleted == 0 then
        utils.show_msg(_("No deleted annotations found for this document."))
        return
    end

    local deleted_menu
    local menu_items = {}

    -- Add Restore All button at the top
    table.insert(menu_items, {
        text = _("Restore All"),
        bold = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = T(_("Are you sure you want to restore all %1 deleted annotations?"), #deleted),
                type = "yesno",
                ok_text = _("Restore All"),
                ok_callback = function()
                    plugin:restoreAnnotations(deleted, true) -- true = silent
                    utils.show_msg(T(_("Restored %1 annotations."), #deleted))
                    if deleted_menu then UIManager:close(deleted_menu) end
                end
            })
        end,
        separator = true,
    })

    for i, ann in ipairs(deleted) do
        local text = ann.text or ann.notes or _("Highlight")
        if text == "" then text = _("Highlight") end
        -- Truncate long text
        if #text > 50 then text = text:sub(1, 47) .. "..." end
        
        table.insert(menu_items, {
            text = text,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Do you want to restore this annotation?\n\nPage %1: %2"), 
                        ann.page, ann.text or ann.notes or ""),
                    type = "yesno",
                    ok_text = _("Restore"),
                    cancel_text = _("Close"),
                    ok_callback = function()
                        plugin:restoreAnnotation(ann)
                    end
                })
            end
        })
    end

    deleted_menu = Menu:new{
        title = _("Deleted Annotations"),
        item_table = menu_items,
    }
    UIManager:show(deleted_menu)
end

function M.show_jump_menu(plugin, progress_map)
    local menu_items = {}
    local jump_menu

    local device_id = plugin.manager:getDeviceName()

    -- Sort devices by percentage descending, breaking ties alphabetically by device name
    local devices = {}
    for dev_id, data in pairs(progress_map) do
        table.insert(devices, { id = dev_id, data = data })
    end
    table.sort(devices, function(a, b)
        local a_pct = a.data.percentage or 0
        local b_pct = b.data.percentage or 0
        if a_pct ~= b_pct then
            return a_pct > b_pct
        end
        return a.id < b.id
    end)

    for idx, dev in ipairs(devices) do
        local is_current = (dev.id == device_id)
        local percentage = (dev.data.percentage or 0) * 100
        local text = string.format("%s: Page %d (%d%%)",
            dev.id, dev.data.page or 0, math.floor(percentage + 0.5))
        if is_current then
            text = text .. " " .. _("(this device)")
        end

        table.insert(menu_items, {
            text = text,
            sub_text = dev.data.timestamp,
            callback = function()
                if dev.data.pos then
                    if plugin.ui.link then
                        plugin.ui.link:onGotoLink({ xpointer = dev.data.pos })
                    else
                        plugin.ui:handleEvent(Event:new("GotoPos", dev.data.pos))
                        UIManager:broadcastEvent(Event:new("GotoPos", dev.data.pos))
                    end
                else
                    plugin.ui:handleEvent(Event:new("GotoPage", dev.data.page))
                    UIManager:broadcastEvent(Event:new("JumpToPage", dev.data.page))
                end
                utils.show_msg(T(_("Jumped to page %1 from %2"), dev.data.page, dev.id))
                UIManager:close(jump_menu)
            end
        })
    end

    if #menu_items == 0 then
        utils.show_msg(_("No remote progress found."))
        return
    end

    jump_menu = Menu:new{
        title = _("Jump to device progress"),
        item_table = menu_items,
    }
    UIManager:show(jump_menu)
end

function M.show_devices_menu(plugin, settings_map)
    local menu_items = {}
    local devices_menu

    local current_device = plugin.manager:getDeviceName()

    -- Sort devices alphabetically by name
    local devices = {}
    for dev_id, data in pairs(settings_map) do
        if dev_id ~= current_device then
            table.insert(devices, { id = dev_id, data = data })
        end
    end
    table.sort(devices, function(a, b)
        return a.id < b.id
    end)

    for _, dev in ipairs(devices) do
        local timestamp = dev.data.timestamp or "unknown"
        local text = string.format("%s (%s)", dev.id, timestamp)
        table.insert(menu_items, {
            text = text,
            callback = function()
                M.show_differing_settings_menu(plugin, dev.id, dev.data.settings or {}, devices_menu)
            end
        })
    end

    if #menu_items == 0 then
        utils.show_msg(_("No other devices found in cloud settings."))
        return
    end

    devices_menu = Menu:new{
        title = _("Pull settings from cloud"),
        item_table = menu_items,
    }
    UIManager:show(devices_menu)
end

local function values_differ(v1, v2)
    if type(v1) ~= type(v2) then
        return true
    end
    if type(v1) == "table" then
        local json = require("json")
        return json.encode(v1) ~= json.encode(v2)
    end
    return v1 ~= v2
end

function M.show_differing_settings_menu(plugin, device_name, remote_settings, parent_menu)
    local menu_items = {}
    local diff_menu

    -- Identify differing settings
    local differing = {}
    local caches = {}
    for key, r_val in pairs(remote_settings) do
        local l_val = plugin.manager:getLocalSettingValue(key, caches)
        if values_differ(l_val, r_val) then
            -- Format values for display
            local function format_val(val)
                if val == nil then return "nil" end
                if type(val) == "boolean" then return val and "true" or "false" end
                if type(val) == "table" then return "{...}" end
                return tostring(val)
            end
            table.insert(differing, {
                key = key,
                local_val_str = format_val(l_val),
                remote_val_str = format_val(r_val),
                remote_val = r_val,
            })
        end
    end

    -- Sort settings alphabetically by key
    table.sort(differing, function(a, b)
        return a.key < b.key
    end)

    if #differing == 0 then
        utils.show_msg(_("No differing settings found for this device."))
        return
    end

    -- Default all to checked
    local checked = {}
    for _, diff in ipairs(differing) do
        checked[diff.key] = true
    end

    -- Action item: Import Selected Settings
    table.insert(menu_items, {
        text = _("Import Selected Settings"),
        bold = true,
        callback = function()
            local count = 0
            for _, diff in ipairs(differing) do
                if checked[diff.key] then
                    if plugin.manager:writeLocalSettingValue(diff.key, diff.remote_val) then
                        count = count + 1
                    end
                end
            end
            if count > 0 then
                plugin.manager:_flushSettings()
                utils.show_msg(T(_("Successfully imported %1 settings."), count))
            else
                utils.show_msg(_("No settings imported."))
            end
            UIManager:close(diff_menu)
            if parent_menu then
                UIManager:close(parent_menu)
            end
        end
    })

    table.insert(menu_items, {
        text = _("Select All"),
        callback = function()
            for _, diff in ipairs(differing) do
                checked[diff.key] = true
            end
            diff_menu:updateItems()
        end
    })

    table.insert(menu_items, {
        text = _("Clear Selection"),
        callback = function()
            checked = {}
            diff_menu:updateItems()
        end,
        separator = true
    })

    for _, diff in ipairs(differing) do
        local setting_id = diff.key
        local domain, full_key = setting_id:match("^([^:]+):(.*)$")
        table.insert(menu_items, {
            text_func = function()
                local is_checked = checked[setting_id]
                local prefix = is_checked and "[✓] " or "[ ] "
                return string.format("%s[%s] %s: %s -> %s",
                    prefix, domain or "unknown", full_key or setting_id, diff.local_val_str, diff.remote_val_str)
            end,
            callback = function()
                checked[setting_id] = not checked[setting_id]
                diff_menu:updateItems()
            end
        })
    end

    diff_menu = Menu:new{
        title = T(_("Settings from %1"), device_name),
        item_table = menu_items,
    }
    UIManager:show(diff_menu)
end

function M.show_pending_documents(plugin)
    local total, changed_docs = plugin.manager:getPendingChangedDocuments()
    if total == 0 then
        utils.show_msg(_("No pending documents to sync."))
        return
    end

    local pending_menu
    local menu_items = {}

    -- Sort the files alphabetically by their clean filename
    local files = {}
    for file, _ in pairs(changed_docs) do
        table.insert(files, file)
    end
    table.sort(files, function(a, b)
        local a_name = a:match("([^/]+)$") or a
        local b_name = b:match("([^/]+)$") or b
        return a_name:lower() < b_name:lower()
    end)

    for i, file in ipairs(files) do
        local clean_filename = file:match("([^/]+)$") or file
        table.insert(menu_items, {
            text = clean_filename,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Do you want to sync this document?\n\n%1"), clean_filename),
                    ok_text = _("Sync now"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        local ui_document = plugin.ui and plugin.ui.document
                        local document = plugin.manager:getDocumentByFile(file)
                        if document then
                            local is_temporary = (document ~= ui_document)
                            utils.show_msg(T(_("Syncing %1..."), clean_filename))
                            local success = plugin.manager:syncDocument(document, true)
                            if is_temporary then
                                document:close()
                            end
                            if success then
                                utils.show_msg(T(_("Successfully synced %1"), clean_filename))
                            else
                                utils.show_msg(T(_("Failed to sync %1"), clean_filename))
                            end
                        else
                            utils.show_msg(T(_("Could not open %1 for sync"), clean_filename))
                        end
                        -- Close pending menu and reopen to refresh the list
                        if pending_menu then UIManager:close(pending_menu) end
                        M.show_pending_documents(plugin)
                    end,
                    other_buttons = {
                        {
                            {
                                text = _("Remove from list"),
                                callback = function()
                                    plugin.manager:removeFromChangedDocumentsFileByPath(file)
                                    utils.show_msg(T(_("Removed %1 from sync list"), clean_filename))
                                    if pending_menu then UIManager:close(pending_menu) end
                                    M.show_pending_documents(plugin)
                                end,
                            }
                        }
                    }
                })
            end
        })
    end

    pending_menu = Menu:new{
        title = _("Pending Documents"),
        item_table = menu_items,
    }
    UIManager:show(pending_menu)
end

return M
