local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Event = require("ui/event")
local _ = require("gettext")
local T = require("ffi/util").template
local utils = require("utils")
local annotations = require("annotations")
local changed_documents = require("changed_documents")
local settings_sync = require("settings_sync")

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local manual_sync_description = "Sync annotations and bookmarks of the active document."
local sync_all_description = "Sync annotations and bookmarks of all unsynced documents with pending modifications."
local sync_all_including_unread_description = "Scan the whole library for books with annotations that have never been synced, and sync them too."

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

    local device_id = utils.get_device_name(plugin)

    -- Sort devices by percentage descending, breaking ties alphabetically by device name
    local devices = {}
    for dev_id, data in pairs(progress_map) do
        if not data.removed then
            table.insert(devices, { id = dev_id, data = data })
        end
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
                local target_page = dev.data.page or 1
                if dev.data.pos and type(dev.data.pos) == "string" then
                    if plugin.ui.link then
                        plugin.ui.link:onGotoLink({ xpointer = dev.data.pos })
                    else
                        plugin.ui:handleEvent(Event:new("GotoPos", dev.data.pos))
                        UIManager:broadcastEvent(Event:new("GotoPos", dev.data.pos))
                    end
                else
                    plugin.ui:handleEvent(Event:new("GotoPage", target_page))
                    UIManager:broadcastEvent(Event:new("JumpToPage", target_page))
                end
                utils.show_msg(T(_("Jumped to page %1 from %2"), target_page, dev.id))
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

    local current_device = utils.get_device_name(plugin)
    local purged_devices = (plugin.settings and plugin.settings.purged_devices) or {}
    local purged_lookup = {}
    for _, dev_id in ipairs(purged_devices) do
        purged_lookup[dev_id] = true
    end

    -- Sort devices alphabetically by name
    local devices = {}
    for dev_id, data in pairs(settings_map) do
        if dev_id ~= current_device and not purged_lookup[dev_id] then
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

function M.show_differing_settings_menu(plugin, device_name, remote_settings, parent_menu)
    local menu_items = {}
    local diff_menu

    -- Identify differing settings
    local differing = {}
    local caches = {}
    for key, r_val in pairs(remote_settings) do
        local l_val = settings_sync.get_local_value(key, caches)
        if settings_sync.values_differ(l_val, r_val) then
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
                    if settings_sync.write_local_value(diff.key, diff.remote_val) then
                        count = count + 1
                    end
                end
            end
            if count > 0 then
                utils.flush_settings()
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

function M.show_purge_device_menu(plugin, progress_map, on_purge)
    local menu_items = {}
    local purge_menu

    local current_device = utils.get_device_name(plugin)

    local devices = {}
    for dev_id in pairs(progress_map) do
        if dev_id ~= current_device then
            table.insert(devices, dev_id)
        end
    end
    table.sort(devices)

    if #devices == 0 then
        utils.show_msg(_("No other devices found in this document's progress."))
        return
    end

    for _idx, dev_id in ipairs(devices) do
        table.insert(menu_items, {
            text = dev_id,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Permanently purge \"%1\" from reading progress sync?"), dev_id),
                    ok_text = _("Purge"),
                    cancel_text = _("Cancel"),
                    ok_callback = function()
                        UIManager:close(purge_menu)
                        on_purge(dev_id)
                    end,
                })
            end,
        })
    end

    purge_menu = Menu:new{
        title = _("Purge device from progress sync"),
        item_table = menu_items,
    }
    UIManager:show(purge_menu)
end

function M.show_purged_devices(plugin, on_unpurge)
    plugin.settings.purged_devices = plugin.settings.purged_devices or {}
    local menu
    local menu_items = {}

    local purged_devices = plugin.settings.purged_devices
    if #purged_devices == 0 then
        table.insert(menu_items, {
            text = _("No devices purged"),
            enabled = false,
        })
    else
        for _idx, dev_id in ipairs(purged_devices) do
            table.insert(menu_items, {
                text = dev_id,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Stop purging \"%1\" going forward?"), dev_id),
                        ok_text = _("Un-purge"),
                        cancel_text = _("Cancel"),
                        ok_callback = function()
                            if menu then UIManager:close(menu) end
                            on_unpurge(dev_id)
                            M.show_purged_devices(plugin, on_unpurge)
                        end,
                    })
                end,
            })
        end
    end

    menu = Menu:new{
        title = _("Purged devices"),
        item_table = menu_items,
    }
    UIManager:show(menu)
end

function M.show_pending_documents(plugin)
    local total, changed_docs = changed_documents.get_pending()
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
                            plugin.manager:syncDocument(document, true, function(success)
                                if is_temporary then
                                    document:close()
                                end
                                if success then
                                    utils.show_msg(T(_("Successfully synced %1"), clean_filename))
                                else
                                    utils.show_msg(T(_("Failed to sync %1"), clean_filename))
                                end
                                -- Close pending menu and reopen to refresh the list
                                if pending_menu then UIManager:close(pending_menu) end
                                M.show_pending_documents(plugin)
                            end)
                        else
                            utils.show_msg(T(_("Could not open %1 for sync"), clean_filename))
                            -- Close pending menu and reopen to refresh the list
                            if pending_menu then UIManager:close(pending_menu) end
                            M.show_pending_documents(plugin)
                        end
                    end,
                    other_buttons = {
                        {
                            {
                                text = _("Remove from list"),
                                callback = function()
                                    changed_documents.remove_by_path(file)
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

function M.build_main_menu(plugin, menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = plugin.settings.menu_location ~= "none" and plugin.settings.menu_location or nil,
        sub_item_table = {
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Cloud settings"),
                        enabled_func = function()
                            return plugin.ui.cloudstorage ~= nil or plugin.has_syncservice
                        end,
                        callback = function()
                            if plugin.ui.cloudstorage then
                                plugin.ui.cloudstorage:onShowCloudStorageList(function(server)
                                    plugin:onSyncServiceConfirm(server)
                                end)
                            elseif plugin.has_syncservice then
                                local sync_service = SyncService:new {}
                                sync_service.onConfirm = function(server)
                                    plugin:onSyncServiceConfirm(server)
                                end
                                UIManager:show(sync_service)
                            end
                        end
                    },
                    {
                        text = _("Use filename instead of hash"),
                        checked_func = function()
                            return plugin.settings.use_filename
                        end,
                        callback = function()
                            plugin.settings.use_filename = not plugin.settings.use_filename
                            plugin:saveSettings()
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Menu location"),
                        sub_item_table = {
                            {
                                text = _("Tools"),
                                checked_func = function()
                                    return plugin.settings.menu_location == "tools"
                                end,
                                callback = function()
                                    plugin.settings.menu_location = "tools"
                                    plugin:saveSettings()
                                end,
                            },
                            {
                                text = _("More tools"),
                                checked_func = function()
                                    return plugin.settings.menu_location == "more_tools"
                                end,
                                callback = function()
                                    plugin.settings.menu_location = "more_tools"
                                    plugin:saveSettings()
                                end,
                            },
                            {
                                text = _("None (shown as new item)"),
                                checked_func = function()
                                    return plugin.settings.menu_location == "none"
                                end,
                                callback = function()
                                    plugin.settings.menu_location = "none"
                                    plugin:saveSettings()
                                end,
                            },
                        },
                    },
                    {
                        text = _("Automatically Sync All when network becomes available"),
                        checked_func = function()
                            return plugin.settings.network_auto_sync
                        end,
                        callback = function()
                            plugin.settings.network_auto_sync = not plugin.settings.network_auto_sync
                            plugin:saveSettings()
                            if plugin.settings.network_auto_sync then
                                plugin:registerEvents()
                            end
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Enable Reading Progress Sync"),
                        enabled_func = function()
                            return plugin.ui.cloudstorage ~= nil
                        end,
                        checked_func = function()
                            return plugin.settings.progress_sync
                        end,
                        callback = function()
                            plugin.settings.progress_sync = not plugin.settings.progress_sync
                            plugin:saveSettings()
                            UIManager:close()
                        end,
                    },
                    {
                        text = _("Sync using last word of page"),
                        enabled_func = function()
                            return plugin.ui.cloudstorage ~= nil and plugin.settings.progress_sync
                        end,
                        checked_func = function()
                            return plugin.settings.progress_sync_last_word
                        end,
                        callback = function()
                            plugin.settings.progress_sync_last_word = not plugin.settings.progress_sync_last_word
                            plugin:saveSettings()
                            UIManager:close()
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Sync every %1 pages"), plugin.settings.progress_sync_interval)
                        end,
                        enabled_func = function()
                            return plugin.ui.cloudstorage ~= nil and plugin.settings.progress_sync
                        end,
                        callback = function()
                            local input
                            input = InputDialog:new{
                                title = _("Sync every # pages"),
                                input = tostring(plugin.settings.progress_sync_interval),
                                input_type = "number",
                                save_callback = function(val)
                                    local n = tonumber(val)
                                    if n and n > 0 then
                                        plugin.settings.progress_sync_interval = math.floor(n)
                                        plugin:saveSettings()
                                        if plugin.ui.menu and plugin.ui.menu.showMainMenu then
                                            plugin.ui.menu:showMainMenu()
                                        end
                                        return true
                                    end
                                end
                            }
                            UIManager:show(input)
                        end,
                    },
                    {
                        text = _("Manage excluded directories (progress sync)"),
                        enabled_func = function()
                            return (plugin.ui.cloudstorage ~= nil or plugin.has_syncservice) and plugin.settings.progress_sync
                        end,
                        callback = function()
                            require("exclude_dirs").show(plugin)
                        end,
                    },
                    {
                        text = _("Manage purged devices"),
                        enabled_func = function()
                            return (plugin.ui.cloudstorage ~= nil or plugin.has_syncservice) and plugin.settings.progress_sync
                        end,
                        callback = function()
                            M.show_purged_devices(plugin, function(device_name)
                                plugin.manager:unpurgeDevice(device_name)
                            end)
                        end,
                    },
                    {
                        text_func = function()
                            local dev_name = plugin.settings.device_name
                            if not dev_name or dev_name == "" then
                                dev_name = require("device").model or "unknown"
                            end
                            return T(_("Device name: %1"), dev_name)
                        end,
                        enabled_func = function()
                            return true
                        end,
                        callback = function()
                            local default_dev_name = require("device").model or "unknown"
                            local current_val = plugin.settings.device_name
                            if not current_val or current_val == "" then
                                current_val = default_dev_name
                            end
                            local input
                            input = InputDialog:new{
                                title = _("Set device name"),
                                description = _("Leave empty to use the default device name."),
                                input = current_val,
                                save_callback = function(val)
                                    local dev_name = val:gsub("^%s*(.-)%s*$", "%1")
                                    if dev_name == default_dev_name then
                                        dev_name = ""
                                    end
                                    plugin.settings.device_name = dev_name
                                    plugin:saveSettings()
                                    if plugin.ui.menu and plugin.ui.menu.showMainMenu then
                                        plugin.ui.menu:showMainMenu()
                                    end
                                    return true
                                end
                            }
                            UIManager:show(input)
                        end,
                    },
                    {
                        text = _("Show changed settings"),
                        callback = function()
                            plugin:showChangedSettings()
                        end,
                    },
                    {
                        enabled = false,
                        text_func = function()
                            local server = plugin.settings.sync_server
                            local cloud_desc = (server and server.url) or _("None")
                            return T(_("Current cloud: %1"), cloud_desc)
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Push settings to cloud"),
                enabled_func = function()
                    return plugin.settings.sync_server ~= nil
                end,
                callback = function()
                    settings_sync.push(plugin)
                end
            },
            {
                text = _("Pull settings from cloud"),
                enabled_func = function()
                    return plugin.settings.sync_server ~= nil
                end,
                callback = function()
                    settings_sync.pull(plugin)
                end
            },
            {
                text = _("Manual Sync"),
                enabled_func = function()
                    return (plugin.settings.sync_server ~= nil) and ((plugin.ui and plugin.ui.document) ~= nil)
                end,
                hold_callback = function()
                    utils.show_msg(manual_sync_description)
                end,
                callback = function()
                    plugin:manualSync()
                end
            },
            {
                text = _("Push reading progress"),
                enabled_func = function()
                    return (plugin.ui.cloudstorage ~= nil or plugin.has_syncservice)
                        and (plugin.settings.sync_server ~= nil)
                        and ((plugin.ui and plugin.ui.document) ~= nil)
                end,
                callback = function()
                    plugin:onAnnotationSyncPushProgress()
                end
            },
            {
                text = _("Jump to device progress"),
                enabled_func = function()
                    return (plugin.ui.cloudstorage ~= nil or plugin.has_syncservice)
                        and (plugin.settings.sync_server ~= nil)
                        and ((plugin.ui and plugin.ui.document) ~= nil)
                end,
                callback = function()
                    plugin.manager:pullProgress()
                end
            },
            {
                text = _("Purge device from progress sync..."),
                enabled_func = function()
                    return (plugin.ui.cloudstorage ~= nil or plugin.has_syncservice)
                        and (plugin.settings.sync_server ~= nil)
                        and ((plugin.ui and plugin.ui.document) ~= nil)
                end,
                callback = function()
                    plugin.manager:purgeDevicePrompt()
                end
            },
            {
                text = _("Sync All"),
                enabled_func = function()
                    return plugin.settings.sync_server ~= nil
                end,
                hold_callback = function()
                    utils.show_msg(sync_all_description)
                end,
                callback = function()
                    plugin.manager:syncAllChangedDocuments()
                end,
            },
            {
                text = _("Sync All (including unread)"),
                enabled_func = function()
                    return plugin.settings.sync_server ~= nil
                end,
                hold_callback = function()
                    utils.show_msg(sync_all_including_unread_description)
                end,
                callback = function()
                    plugin.manager:scanAndSyncAllBooks()
                end,
                separator = true,
            },
            {
                text = _("Show pending/unsynced documents"),
                enabled = true,
                callback = function()
                    M.show_pending_documents(plugin)
                end,
            },
            {
                text = _("Show Deleted"),
                enabled_func = function()
                    return (plugin.ui and plugin.ui.document) ~= nil
                end,
                callback = function()
                    plugin:showDeletedAnnotations()
                end,
                separator = true,
            },
            {
                enabled = false,
                text_func = function()
                   return T(_("Last sync: %1"), plugin.settings.last_sync)
                end
            },
            {
                text = T(_("Plugin version: %1"), plugin.version),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1 (%4)\nVersion: %2\n\n%3"), plugin.fullname, plugin.version, plugin.description, plugin.plugin_id),
                    })
                end,
            },
        }
    }

    if plugin.ui.cloudstorage == nil and not plugin.has_syncservice then
        table.insert(menu_items.annotation_sync_plugin.sub_item_table, {
            text = _("Why are some options greyed out?"),
            callback = function()
                UIManager:show(InfoMessage:new{
                    text = _("Reading progress sync features are disabled because your KOReader version does not support the cloudstorage plugin.\n\nThese features require a newer KOReader release (not yet available in stable releases)."),
                })
            end,
        })
    end
end

return M
