local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}

-- Suppresses the "Successfully synchronized." toast for the duration of func,
-- restoring UIManager.show afterwards (or after a 15s timeout, whichever first).
function M.run_silent(func, on_timeout)
    local old_show = UIManager.show
    local new_show
    new_show = function(self, widget_item)
        if widget_item.text == _("Successfully synchronized.") then
            return
        end
        return old_show(self, widget_item)
    end
    UIManager.show = new_show

    local restored = false
    local function restore()
        if not restored then
            restored = true
            if UIManager.show == new_show then
                UIManager.show = old_show
            end
        end
    end

    UIManager:scheduleIn(15, function()
        if not restored then
            if on_timeout then
                on_timeout()
            end
            restore()
        end
    end)

    func(restore)
end

return M
