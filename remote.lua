local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local annotations = require("annotations")

local M = {}

function M.sync_annotations(widget, document, json_path, on_complete, force)
    if not widget.ui.cloudstorage then
        UIManager:show(InfoMessage:new {
            text = _("Cloud Storage plugin is not enabled or available."),
            timeout = 4
        })
        if on_complete then
            on_complete(false)
        end
        return
    end

    local server = widget.settings.sync_server
    if server then
        widget.ui.cloudstorage:sync(server, json_path, function(local_file, cached_file, income_file)
            local success, merged_list = annotations.sync_callback(document, local_file, cached_file, income_file, force)
            if on_complete then
                on_complete(success, merged_list)
            end
            return success
        end, not force)
    else
        UIManager:show(InfoMessage:new {
            text = T(_("No cloud destination set in settings.")),
            timeout = 4
        })
        if on_complete then
            on_complete(false)
        end
    end
end

return M
