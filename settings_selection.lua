local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local DataStorage = require("datastorage")
local Menu = require("ui/widget/menu")
local _ = require("gettext")
local T = require("ffi/util").template

local SettingsSelection = {}

function SettingsSelection.show(plugin)
    plugin.settings.selected_settings = plugin.settings.selected_settings or {}
    local root = { type = "branch", children = {} }
    local excluded = {
        -- Global reader settings (settings.reader.lua)
        ["reader:device_id"] = true,
        ["reader:device_name"] = true,
        ["reader:lastfile"] = true,
        ["reader:home_dir"] = true,
        ["reader:fontmap"] = true,
        ["reader:color_rendering"] = true,
        ["reader:folder_shortcuts_settings"] = true,
        ["reader:cloud_server_object"] = true,
        ["reader:cloud_download_dir"] = true,
        ["reader:cloud_provider_type"] = true,
        ["reader:dict_presets"] = true,
        ["reader:dicts_disabled"] = true,
        ["reader:dicts_order"] = true,
        ["reader:input_ignore_gsensor"] = true,
        ["reader:input_lock_gsensor"] = true,
        ["reader:input_invert_page_turn_keys"] = true,
        ["reader:input_invert_left_page_turn_keys"] = true,
        ["reader:input_invert_right_page_turn_keys"] = true,
        ["reader:timezone"] = true,
        ["reader:annotation_sync_plugin"] = true,
        ["reader:AnnotationSync"] = true,
        ["reader:sdl_window"] = true,

        -- Expanded Font and Path settings exclusions:
        ["reader:cre_font_family_fonts"] = true,
        ["reader:cre_fonts_recently_selected"] = true,
        ["reader:cover_image_cache_path"] = true,
        ["reader:cover_image_fallback_path"] = true,
        ["reader:document_metadata_folder"] = true,

        -- Plugin settings / databases / logs
        ["settings/cloudstorage"] = true,
        ["settings/battery_stats"] = true,
        ["settings/profiles"] = true,
        ["settings/terminal"] = true,
        ["settings/bookinfo_cache"] = true,
        ["settings/statistics"] = true,
        ["settings/vocabulary_builder"] = true,
    }

    local function is_array(t)
        if type(t) ~= "table" then return false end
        local count = 0
        for _ in pairs(t) do
            count = count + 1
        end
        for i = 1, count do
            if t[i] == nil then
                return false
            end
        end
        return true
    end

    local function format_val(val)
        if val == nil then
            return "nil"
        elseif type(val) == "boolean" then
            return val and "true" or "false"
        elseif type(val) == "table" then
            if is_array(val) then
                local parts = {}
                for _, v in ipairs(val) do
                    table.insert(parts, format_val(v))
                end
                return "[" .. table.concat(parts, ", ") .. "]"
            else
                return "{dictionary}"
            end
        else
            return tostring(val)
        end
    end

    local function is_excluded(domain, path)
        local full_path = domain .. ":" .. table.concat(path, ".")
        if excluded[full_path] then
            return true
        end
        for i = 1, #path do
            local sub_path = domain .. ":" .. table.concat(path, ".", 1, i)
            if excluded[sub_path] then
                return true
            end
        end
        return false
    end

    local function build_diff_tree(domain, vanilla, active, path, parent_node)
        if is_excluded(domain, path) then
            return
        end

        local v_is_table = type(vanilla) == "table"
        local a_is_table = type(active) == "table"

        -- Case 1: Both are primitive values
        if not v_is_table and not a_is_table then
            if vanilla ~= active then
                table.insert(parent_node.children, {
                    type = "leaf",
                    domain = domain,
                    key = path[#path],
                    full_key = table.concat(path, "."),
                    vanilla = format_val(vanilla),
                    active = format_val(active)
                })
            end
            return
        end

        -- Case 2: One is a table and the other is not
        if v_is_table ~= a_is_table then
            local tbl = v_is_table and vanilla or active
            if is_array(tbl) then
                table.insert(parent_node.children, {
                    type = "leaf",
                    domain = domain,
                    key = path[#path],
                    full_key = table.concat(path, "."),
                    vanilla = format_val(vanilla),
                    active = format_val(active)
                })
            else
                local branch = {
                    type = "branch",
                    domain = domain,
                    key = path[#path],
                    full_key = table.concat(path, "."),
                    children = {}
                }
                local keys = {}
                if v_is_table then
                    for k in pairs(vanilla) do keys[k] = true end
                else
                    for k in pairs(active) do keys[k] = true end
                end
                for k in pairs(keys) do
                    table.insert(path, k)
                    build_diff_tree(domain, v_is_table and vanilla[k] or nil, a_is_table and active[k] or nil, path, branch)
                    table.remove(path)
                end
                if #branch.children > 0 then
                    table.insert(parent_node.children, branch)
                end
            end
            return
        end

        -- Case 3: Both are tables
        local v_is_array = is_array(vanilla)
        local a_is_array = is_array(active)

        if v_is_array or a_is_array then
            local v_str = format_val(vanilla)
            local a_str = format_val(active)
            if v_str ~= a_str then
                table.insert(parent_node.children, {
                    type = "leaf",
                    domain = domain,
                    key = path[#path],
                    full_key = table.concat(path, "."),
                    vanilla = v_str,
                    active = a_str
                })
            end
            return
        end

        -- Both are dictionaries
        local branch = {
            type = "branch",
            domain = domain,
            key = path[#path],
            full_key = table.concat(path, "."),
            children = {}
        }

        local all_keys = {}
        for k in pairs(vanilla) do all_keys[k] = true end
        for k in pairs(active) do all_keys[k] = true end

        for k in pairs(all_keys) do
            table.insert(path, k)
            build_diff_tree(domain, vanilla[k], active[k], path, branch)
            table.remove(path)
        end

        if #branch.children > 0 then
            table.insert(parent_node.children, branch)
        end
    end

    local function compare_settings_file(domain, vanilla_path, active_path, parent_node)
        local ok_v, vanilla_tbl = pcall(dofile, vanilla_path)
        local ok_a, active_tbl = pcall(dofile, active_path)

        local all_keys = {}
        if ok_v and type(vanilla_tbl) == "table" then
            for k in pairs(vanilla_tbl) do all_keys[k] = true end
        end
        if ok_a and type(active_tbl) == "table" then
            for k in pairs(active_tbl) do all_keys[k] = true end
        end
        for k in pairs(all_keys) do
            build_diff_tree(domain, ok_v and vanilla_tbl and vanilla_tbl[k], ok_a and active_tbl and active_tbl[k], {k}, parent_node)
        end
    end

    -- 1. Compare settings.reader.lua
    compare_settings_file("reader", plugin.path .. "/defaults/settings.reader.lua", DataStorage:getDataDir() .. "/settings.reader.lua", root)

    -- 2. Compare defaults.custom.lua
    compare_settings_file("defaults", plugin.path .. "/defaults/defaults.custom.lua", DataStorage:getDataDir() .. "/defaults.custom.lua", root)

    -- 3. Compare files in settings/ directory
    local vanilla_settings_dir = plugin.path .. "/defaults/settings"
    local active_settings_dir = DataStorage:getSettingsDir()
    
    if lfs.attributes(vanilla_settings_dir, "mode") == "directory" then
        for entry in lfs.dir(vanilla_settings_dir) do
            if entry ~= "." and entry ~= ".." then
                local filepath = vanilla_settings_dir .. "/" .. entry
                local mode = lfs.attributes(filepath, "mode")
                if mode == "file" and entry:match("%.lua$") then
                    local name = entry:gsub("%.lua$", "")
                    local domain = "settings/" .. name
                    if not excluded[domain] then
                        local file_branch = {
                            type = "branch",
                            domain = domain,
                            key = name,
                            full_key = name,
                            children = {}
                        }
                        
                        compare_settings_file(domain, filepath, active_settings_dir .. "/" .. entry, file_branch)
                        
                        if #file_branch.children > 0 then
                            table.insert(root.children, file_branch)
                        end
                    end
                end
            end
        end
    end

    local function get_all_leaf_keys(n, keys)
        keys = keys or {}
        for _, child in ipairs(n.children) do
            if child.type == "branch" then
                get_all_leaf_keys(child, keys)
            else
                table.insert(keys, child.domain .. ":" .. child.full_key)
            end
        end
        return keys
    end

    local function show_node_menu(node, title)
        local menu_items = {}
        local submenu
        
        table.sort(node.children, function(a, b)
            if a.type ~= b.type then
                return a.type == "branch"
            end
            return a.key < b.key
        end)

        if #node.children > 0 then
            table.insert(menu_items, {
                text = _("Select All"),
                callback = function()
                    local keys = get_all_leaf_keys(node)
                    plugin.settings.selected_settings = plugin.settings.selected_settings or {}
                    for _, key in ipairs(keys) do
                        plugin.settings.selected_settings[key] = true
                    end
                    plugin:saveSettings()
                    if submenu then
                        submenu:updateItems()
                    end
                end
            })
            table.insert(menu_items, {
                text = _("Clear Selection"),
                callback = function()
                    local keys = get_all_leaf_keys(node)
                    if plugin.settings.selected_settings then
                        for _, key in ipairs(keys) do
                            plugin.settings.selected_settings[key] = nil
                        end
                    end
                    plugin:saveSettings()
                    if submenu then
                        submenu:updateItems()
                    end
                end,
                separator = true,
            })
        end

        for _, child in ipairs(node.children) do
            if child.type == "branch" then
                table.insert(menu_items, {
                    text_func = function()
                        local keys = get_all_leaf_keys(child)
                        local any_selected = false
                        for _, key in ipairs(keys) do
                            if plugin.settings.selected_settings and plugin.settings.selected_settings[key] then
                                any_selected = true
                                break
                            end
                        end
                        local prefix = any_selected and "[✓] " or "[ ] "
                        return string.format("%s[%s] %s >", prefix, child.domain, child.full_key)
                    end,
                    callback = function()
                        show_node_menu(child, child.full_key)
                    end
                })
            else
                local setting_id = child.domain .. ":" .. child.full_key
                table.insert(menu_items, {
                    text_func = function()
                        local is_selected = plugin.settings.selected_settings and plugin.settings.selected_settings[setting_id]
                        local prefix = is_selected and "[✓] " or "[ ] "
                        return string.format("%s[%s] %s: %s -> %s", 
                            prefix, child.domain, child.full_key, child.vanilla, child.active)
                    end,
                    callback = function()
                        plugin.settings.selected_settings = plugin.settings.selected_settings or {}
                        plugin.settings.selected_settings[setting_id] = not plugin.settings.selected_settings[setting_id] or nil
                        plugin:saveSettings()
                        if submenu then
                            local idx = 1
                            for i, item in ipairs(menu_items) do
                                if item.setting_id == setting_id then
                                    idx = i
                                    break
                                end
                            end
                            submenu:updateItems(idx, true)
                        end
                    end,
                    setting_id = setting_id,
                })
            end
        end

        if #menu_items == 0 then
            table.insert(menu_items, {
                text = _("No changed settings found."),
                enabled = false
            })
        end

        submenu = Menu:new{
            title = title,
            item_table = menu_items,
        }
        UIManager:show(submenu)
    end

    show_node_menu(root, _("Changed Settings"))
end

return SettingsSelection
