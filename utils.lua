local reader_order = require("ui/elements/reader_menu_order")
local M = {}

function M.read_json(path)
    local f = io.open(path, "r")
    if not f then
        return {}
    end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then
        return {}
    end
    local ok, data = pcall(json.decode, content)
    if ok and type(data) == "table" then
        if data.error_summary or (data.error and type(data.error) == "table") then
            return {}
        end
        return data
    end
    return {}
end

function M.insert_after_statistics(key)
    local pos = 1
    for index, value in ipairs(reader_order.tools) do
        if value == "statistics" then
            pos = index + 1
            break
        end
    end
    table.insert(reader_order.tools, pos, key)
end

return M
