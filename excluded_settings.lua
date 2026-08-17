local M = {}

-- Domain-scoped keys and whole domains never eligible for selection or sync.
M.excluded = {
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

    -- Plugin settings / databases / logs (whole domain excluded)
    ["settings/cloudstorage"] = true,
    ["settings/battery_stats"] = true,
    ["settings/profiles"] = true,
    ["settings/terminal"] = true,
    ["settings/bookinfo_cache"] = true,
    ["settings/statistics"] = true,
    ["settings/vocabulary_builder"] = true,
}

function M.is_domain_excluded(domain)
    return M.excluded[domain] == true
end

-- Excludes "domain:key", "domain:key.nested" (nested keys inherit an
-- excluded parent's exclusion) and whole excluded domains.
function M.is_key_excluded(key)
    local domain, full_key = key:match("^([^:]+):(.*)$")
    if not domain then
        return false
    end
    if M.is_domain_excluded(domain) then
        return true
    end

    local prefix
    for part in full_key:gmatch("[^%.]+") do
        prefix = prefix and (prefix .. "." .. part) or part
        if M.excluded[domain .. ":" .. prefix] then
            return true
        end
    end
    return false
end

return M
