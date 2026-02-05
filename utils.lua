local reader_order = require("ui/elements/reader_menu_order")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local json = require("json")

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
            return nil
        end
        return data
    end
    return nil
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

function M.show_msg(msg)
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })
end

return M
