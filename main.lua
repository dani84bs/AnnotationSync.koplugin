local docsettings = require("frontend/docsettings")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local Dispatcher = require("dispatcher")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local ReaderAnnotation = require("apps/reader/modules/readerannotation")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local json = require("json")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local _ = require("gettext")
local DataStorage = require("datastorage")
local logger = require("logger")

local annotations = require("annotations")
local remote = require("remote")
local utils = require("utils")
local SyncManager = require("manager")

local has_syncservice, SyncService = pcall(require, "apps/cloudstorage/syncservice")

local manual_sync_description = "Sync annotations and bookmarks of the active document."
local sync_all_description = "Sync annotations and bookmarks of all unsynced documents with pending modifications."
local jump_to_device_progress_description = "Jump to the reading progress of another device."

local AnnotationSyncPlugin = WidgetContainer:extend {
    -- see also: _meta.lua
    is_doc_only = false,

    settings = nil,
    manager = nil,
}

AnnotationSyncPlugin.default_settings = {
    last_sync = "Never",
    use_filename= false,
    network_auto_sync = false,
    progress_sync = false,
    progress_sync_interval = 1,
    progress_sync_last_word = false,
    device_name = "",
}

function AnnotationSyncPlugin:init()
    self.ui.menu:registerToMainMenu(self)

    -- Ensure the plugin is in the ReaderUI event chain
    local found = false
    for _, child in ipairs(self.ui) do
        if child == self then
            found = true
            break
        end
    end
    if not found then
        table.insert(self.ui, self)
    end

    utils.insert_after_statistics(self.plugin_id)
    self:onDispatcherRegisterActions()

    self.settings = G_reader_settings:readSetting(self.plugin_id, util.tableDeepCopy(self.default_settings))

    -- Fallback/migration for legacy cloud_server_object
    if not self.settings.sync_server then
        local server_json = G_reader_settings:readSetting("cloud_server_object")
        if server_json and server_json ~= "" then
            local ok, server = pcall(json.decode, server_json)
            if ok and server then
                self.settings.sync_server = server
                self:saveSettings()
            end
        end
    end

    -- Sanitize corrupted settings
    if type(self.settings.progress_sync_interval) ~= "number" then
        self.settings.progress_sync_interval = self.default_settings.progress_sync_interval
    end

    self.manager = SyncManager:new(self)

    -- Migrate old annotation_sync_use_filename setting
    if G_reader_settings:has("annotation_sync_use_filename") then
        self.settings.use_filename = G_reader_settings:isTrue("annotation_sync_use_filename")
        G_reader_settings:delSetting("annotation_sync_use_filename")
    end

    self.settings_key = self.plugin_id

    self:registerEvents()
end

function AnnotationSyncPlugin:saveSettings()
    G_reader_settings:saveSetting(self.plugin_id, self.settings)
end

function AnnotationSyncPlugin:deletePluginSettings()
    G_reader_settings:delSetting(self.plugin_id)
    G_reader_settings:delSetting("cloud_server_object")
    G_reader_settings:delSetting("cloud_download_dir")
    G_reader_settings:delSetting("cloud_provider_type")

    local track_path
    if self.manager then
        track_path = self.manager:changedDocumentsFile()
    else
        track_path = DataStorage:getDataDir() .. "/changed_documents.lua"
    end
    if track_path and util.fileExists(track_path) then
        os.remove(track_path)
    end
end

function AnnotationSyncPlugin:addToMainMenu(menu_items)
    menu_items.annotation_sync_plugin = {
        text = _("Annotation Sync"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Cloud settings"),
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil or has_syncservice
                        end,
                        callback = function()
                            if self.ui.cloudstorage then
                                self.ui.cloudstorage:onShowCloudStorageList(function(server)
                                    self:onSyncServiceConfirm(server)
                                end)
                            elseif has_syncservice then
                                local sync_service = SyncService:new {}
                                sync_service.onConfirm = function(server)
                                    self:onSyncServiceConfirm(server)
                                end
                                UIManager:show(sync_service)
                            end
                        end
                    },
                    {
                        text = _("Use filename instead of hash"),
                        checked_func = function()
                            return self.settings.use_filename
                        end,
                        callback = function()
                            self.settings.use_filename = not self.settings.use_filename
                            self:saveSettings()
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Automatically Sync All when network becomes available"),
                        checked_func = function()
                            return self.settings.network_auto_sync
                        end,
                        callback = function()
                            self.settings.network_auto_sync = not self.settings.network_auto_sync
                            self:saveSettings()
                            if self.settings.network_auto_sync then
                                self:registerEvents()
                            end
                            UIManager:close()
                        end
                    },
                    {
                        text = _("Enable Reading Progress Sync"),
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil
                        end,
                        checked_func = function()
                            return self.settings.progress_sync
                        end,
                        callback = function()
                            self.settings.progress_sync = not self.settings.progress_sync
                            self:saveSettings()
                            UIManager:close()
                        end,
                    },
                    {
                        text = _("Sync using last word of page"),
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil and self.settings.progress_sync
                        end,
                        checked_func = function()
                            return self.settings.progress_sync_last_word
                        end,
                        callback = function()
                            self.settings.progress_sync_last_word = not self.settings.progress_sync_last_word
                            self:saveSettings()
                            UIManager:close()
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Sync every %1 pages"), self.settings.progress_sync_interval)
                        end,
                        enabled_func = function()
                            return self.ui.cloudstorage ~= nil and self.settings.progress_sync
                        end,
                        callback = function()
                            local input
                            input = InputDialog:new{
                                title = _("Sync every # pages"),
                                input = tostring(self.settings.progress_sync_interval),
                                input_type = "number",
                                save_callback = function(val)
                                    local n = tonumber(val)
                                    if n and n > 0 then
                                        self.settings.progress_sync_interval = math.floor(n)
                                        self:saveSettings()
                                        if self.ui.menu and self.ui.menu.showMainMenu then
                                            self.ui.menu:showMainMenu()
                                        end
                                        return true
                                    end
                                end
                            }
                            UIManager:show(input)
                        end,
                    },
                    {
                        text_func = function()
                            local dev_name = self.settings.device_name
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
                            local current_val = self.settings.device_name
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
                                    self.settings.device_name = dev_name
                                    self:saveSettings()
                                    if self.ui.menu and self.ui.menu.showMainMenu then
                                        self.ui.menu:showMainMenu()
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
                            self:showChangedSettings()
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Manual Sync"),
                enabled = ((G_reader_settings:readSetting("cloud_download_dir") or "") ~= "") and ((self.ui and self.ui.document) ~= nil),
                hold_callback = function()
                    utils.show_msg(manual_sync_description)
                end,
                callback = function()
                    self:manualSync()
                end
            },
            {
                text = _("Jump to device progress"),
                enabled_func = function()
                    return self.ui.cloudstorage ~= nil
                        and ((G_reader_settings:readSetting("cloud_download_dir") or "") ~= "")
                        and ((self.ui and self.ui.document) ~= nil)
                end,
                callback = function()
                    self.manager:pullProgress()
                end
            },
            {
                text = _("Sync All"),
                enabled = true,
                hold_callback = function()
                    utils.show_msg(sync_all_description)
                end,
                callback = function()
                    self.manager:syncAllChangedDocuments()
                end,
                separator = true,
            },
            {
                text = _("Show Deleted"),
                enabled = ((self.ui and self.ui.document) ~= nil),
                callback = function()
                    self:showDeletedAnnotations()
                end,
                separator = true,
            },
            {
                enabled = false,
                text_func = function()
                   return T(_("Last sync: %1"), self.settings.last_sync)
                end
            },
            {
                text = T(_("Plugin version: %1"), self.version),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("%1 (%4)\nVersion: %2\n\n%3"), self.fullname, self.version, self.description, self.plugin_id),
                    })
                end,
            },
        }
    }

    if self.ui.cloudstorage == nil then
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

function AnnotationSyncPlugin:registerEvents()
    if self.settings.network_auto_sync then
        self.onNetworkConnected = self._onNetworkConnected
    else
        self.onNetworkConnected = nil
    end
end

function AnnotationSyncPlugin:_onNetworkConnected()
    logger.dbg("AnnotationSync: handling event: NetworkConnected")
    if self.manager:hasPendingChangedDocuments() then
        utils.show_msg("AnnotationSync: Network available, syncing all changed documents")
        UIManager:scheduleIn(1, function()
            self.manager:syncAllChangedDocuments()
        end)
    end
end

function AnnotationSyncPlugin:applySyncedAnnotations(document, merged_list)
    if self.ui and self.ui.annotation and self.ui.document == document then
        -- 1. Sort for UI consistency
        table.sort(merged_list, function(a, b)
            local cmp = annotations.compare_positions(a.page, b.page, document)
            return (cmp or 0) > 0
        end)
        -- 2. Update active widget state
        self.ui.annotation.annotations = merged_list
        self.ui.annotation:onSaveSettings()

        -- 3. Notify system
        if #merged_list > 0 then
            UIManager:broadcastEvent(Event:new("AnnotationsModified", merged_list))
        end

        -- 4. Trigger Refreshes
        if not document.is_pdf then
            document:render()
            self.ui.view:recalculate()
            UIManager:setDirty(self.ui.view.dialog, "partial")
        end
    else
        -- Update sidecar directly for inactive document
        local annotation_sidecar = docsettings:open(document.file)
        annotation_sidecar:saveSetting("annotations", merged_list)
        annotation_sidecar:flush()
    end
end

function AnnotationSyncPlugin:onAnnotationSyncSyncAll()
    self.manager:syncAllChangedDocuments()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncManualSync()
    self:manualSync()
    return true
end

function AnnotationSyncPlugin:onAnnotationSyncJumpToDeviceProgress()
    if not self.ui.cloudstorage then
        utils.show_msg(_("Reading progress sync is not supported on this version of KOReader."))
        return true
    end
    local document = self.ui and self.ui.document
    if not document or not document.file then
        utils.show_msg(_("A document must be active to jump to device progress."))
        return true
    end
    self.manager:pullProgress()
    return true
end

function AnnotationSyncPlugin:onPageUpdate(page_pos)
    if self.manager then
        self.manager:onPageUpdate(page_pos)
    end
end

function AnnotationSyncPlugin:onPosUpdate(page_pos)
    if self.manager then
        self.manager:onPageUpdate(page_pos)
    end
end

function AnnotationSyncPlugin:onPagePositionUpdated(page_pos)
    if self.manager then
        self.manager:onPageUpdate(page_pos)
    end
end

function AnnotationSyncPlugin:onCloseDocument()
    if self.manager then
        self.manager:onCloseDocument()
    end
end

function AnnotationSyncPlugin:onSuspend()
    if self.manager then
        self.manager:onSuspend()
    end
end

function AnnotationSyncPlugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("annotation_sync_manual_sync", {
        category = "none",
        event = "AnnotationSyncManualSync",
        title = _("AnnotationSync: Manual Sync"),
        text = _(manual_sync_description),
        separator = true,
        reader = true
    })
    Dispatcher:registerAction("annotation_sync_jump_to_device_progress", {
        category = "none",
        event = "AnnotationSyncJumpToDeviceProgress",
        title = _("AnnotationSync: Jump to device progress"),
        text = _(jump_to_device_progress_description),
        separator = true,
        reader = true
    })
    Dispatcher:registerAction("annotation_sync_sync_all", {
        category = "none",
        event = "AnnotationSyncSyncAll",
        title = _("AnnotationSync: Sync All"),
        text = _(sync_all_description),
        separator = true,
        general = true
    })
end

function AnnotationSyncPlugin:onSyncServiceConfirm(server)
    self.settings.sync_server = server
    self:saveSettings()

    -- Keep G_reader_settings updated for legacy compatibility and menu enablement
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_download_dir", server.url)
    if server.type then
        G_reader_settings:saveSetting("cloud_provider_type", server.type)
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Cloud destination set to:\n%1\nProvider: %2"),
            server.url, server.type or "unknown"),
        timeout = 4
    })
    if self and self.ui and self.ui.menu and self.ui.menu.showMainMenu then
        self.ui.menu:showMainMenu()
    end
end

function AnnotationSyncPlugin:manualSync()
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then
        utils.show_msg("A document must be active to do a manual sync.")
        return
    end
    self.manager:syncDocument(document, true)
    self.manager:updateLastSync("Manual Sync")
end

function AnnotationSyncPlugin:showDeletedAnnotations()
    local document = self.ui and self.ui.document
    if not document then return end

    local deleted = self.manager:getDeletedAnnotations(document)
    if #deleted == 0 then
        utils.show_msg(_("No deleted annotations found for this document."))
        return
    end

    local Menu = require("ui/widget/menu")
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
                    for _, ann in ipairs(deleted) do
                        self:restoreAnnotation(ann, true) -- true = silent
                    end
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
                        self:restoreAnnotation(ann)
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

function AnnotationSyncPlugin:restoreAnnotation(ann, silent)
    local document = self.ui and self.ui.document
    if not document then return end

    -- 1. Mark as not deleted and update timestamp
    ann.deleted = false
    ann.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
    
    -- 2. Add back to current list
    local current = self.manager:getAnnotationsForDocument(document)
    table.insert(current, ann)
    
    -- 3. Apply changes (saves to sidecar and refreshes UI)
    self:applySyncedAnnotations(document, current)

    -- 4. Flush to local sync JSON immediately (Fix for Issue #39 delayed flush)
    self.manager:writeAnnotationsJSON(document)

    if not silent then
        utils.show_msg(_("Annotation restored."))
    end
end

function AnnotationSyncPlugin:onAnnotationsModified(annotations)
    if not annotations and type(annotations) == "table" then
        logger.warn("AnnotationSync: Document annotations modification detected, but could not process provided annotations payload (of type: " .. type(annotations) .. ")")
        return
    end

    -- only want to handle each changed file once, so let's keep track
    local changed_files = {}
    local unknown_file = "unknown_file"

    -- find changed files for payload annotations
    for _, annotation in ipairs(annotations) do
        local changed_file = annotation.book_path
        -- AnnotationsModified event payload does not include book_path for an active document
        if not changed_file then
            changed_file = self.ui and self.ui.document and self.ui.document.file
        end
        if not changed_file then
            changed_file = unknown_file
        end
        local count = changed_files[changed_file]
        changed_files[changed_file] = (count and count + 1) or 1
    end

    -- handle changed files
    for changed_file, changes in pairs(changed_files) do
        if changed_file == unknown_file then
            if changes > 0 then
                logger.warn("AnnotationSync: Document annotations modification detected, but could not determine file for " .. changes .. " annotations")
            end
        else
            logger.dbg("AnnotationSync: " .. changes .. " Document annotations modified: " .. changed_file)
            self.manager:addToChangedDocumentsFile(changed_file)
        end
    end
end

function AnnotationSyncPlugin:showChangedSettings()
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
        ["reader:annotation_sync_plugin.last_sync"] = true,
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

    -- 1. Compare settings.reader.lua
    local vanilla_reader_path = self.path .. "/defaults/settings.reader.lua"
    local active_reader_path = DataStorage:getDataDir() .. "/settings.reader.lua"
    local ok_v, vanilla_reader = pcall(dofile, vanilla_reader_path)
    local ok_a, active_reader = pcall(dofile, active_reader_path)
    
    local all_keys_reader = {}
    if ok_v and type(vanilla_reader) == "table" then
        for k in pairs(vanilla_reader) do all_keys_reader[k] = true end
    end
    if ok_a and type(active_reader) == "table" then
        for k in pairs(active_reader) do all_keys_reader[k] = true end
    end
    for k in pairs(all_keys_reader) do
        build_diff_tree("reader", ok_v and vanilla_reader and vanilla_reader[k], ok_a and active_reader and active_reader[k], {k}, root)
    end

    -- 2. Compare defaults.custom.lua
    local vanilla_defaults_path = self.path .. "/defaults/defaults.custom.lua"
    local active_defaults_path = DataStorage:getDataDir() .. "/defaults.custom.lua"
    local ok_vd, vanilla_defaults = pcall(dofile, vanilla_defaults_path)
    local ok_ad, active_defaults = pcall(dofile, active_defaults_path)

    local all_keys_defaults = {}
    if ok_vd and type(vanilla_defaults) == "table" then
        for k in pairs(vanilla_defaults) do all_keys_defaults[k] = true end
    end
    if ok_ad and type(active_defaults) == "table" then
        for k in pairs(active_defaults) do all_keys_defaults[k] = true end
    end
    for k in pairs(all_keys_defaults) do
        build_diff_tree("defaults", ok_vd and vanilla_defaults and vanilla_defaults[k], ok_ad and active_defaults and active_defaults[k], {k}, root)
    end

    -- 3. Compare files in settings/ directory
    local vanilla_settings_dir = self.path .. "/defaults/settings"
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
                        local ok_vs, v_tbl = pcall(dofile, filepath)
                        local ok_as, a_tbl = pcall(dofile, active_settings_dir .. "/" .. entry)
                        
                        local all_keys_settings = {}
                        if ok_vs and type(v_tbl) == "table" then
                            for k in pairs(v_tbl) do all_keys_settings[k] = true end
                        end
                        if ok_as and type(a_tbl) == "table" then
                            for k in pairs(a_tbl) do all_keys_settings[k] = true end
                        end
                        
                        local file_branch = {
                            type = "branch",
                            domain = domain,
                            key = name,
                            full_key = name,
                            children = {}
                        }
                        
                        for k in pairs(all_keys_settings) do
                            build_diff_tree(domain, ok_vs and v_tbl and v_tbl[k], ok_as and a_tbl and a_tbl[k], {k}, file_branch)
                        end
                        
                        if #file_branch.children > 0 then
                            table.insert(root.children, file_branch)
                        end
                    end
                end
            end
        end
    end

    local function show_node_menu(node, title)
        local menu_items = {}
        
        table.sort(node.children, function(a, b)
            if a.type ~= b.type then
                return a.type == "branch"
            end
            return a.key < b.key
        end)

        for _, child in ipairs(node.children) do
            if child.type == "branch" then
                local text = string.format("[%s] %s >", child.domain, child.full_key)
                table.insert(menu_items, {
                    text = text,
                    callback = function()
                        show_node_menu(child, child.full_key)
                    end
                })
            else
                local text = string.format("[%s] %s: %s -> %s", 
                    child.domain, child.full_key, child.vanilla, child.active)
                table.insert(menu_items, {
                    text = text,
                    callback = function() end
                })
            end
        end

        if #menu_items == 0 then
            table.insert(menu_items, {
                text = _("No changed settings found."),
                enabled = false
            })
        end

        local Menu = require("ui/widget/menu")
        local submenu = Menu:new{
            title = title,
            item_table = menu_items,
        }
        UIManager:show(submenu)
    end

    show_node_menu(root, _("Changed Settings"))
end

return AnnotationSyncPlugin
