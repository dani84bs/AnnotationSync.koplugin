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

    -- json.decode can cause a panic and crash KOReader on some platforms if it
    -- tries to parse HTML, even in a `pcall()`
    if not M.isPossiblyJson(content) then
        return nil
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

function M.isPossiblyJson(content)
    local first_char = content:sub(1, 1)
    return first_char == "{" or first_char == "["
end

function M.show_msg(msg)
    UIManager:show(InfoMessage:new{
        text = msg,
        timeout = 3,
    })
end

local function strip_trailing_slash(path)
    if path ~= "/" then
        path = path:gsub("/+$", "")
    end
    return path
end

function M.is_path_excluded(dir, excluded_dirs)
    if not dir or not excluded_dirs then return false end
    dir = strip_trailing_slash(dir)
    for _, excluded in ipairs(excluded_dirs) do
        excluded = strip_trailing_slash(excluded)
        if excluded == "/" then
            if dir:sub(1, 1) == "/" then return true end
        elseif dir == excluded or dir:sub(1, #excluded + 1) == excluded .. "/" then
            return true
        end
    end
    return false
end

function M.get_nested_value(tbl, path_str)
    if not tbl then return nil end
    local parts = {}
    for part in string.gmatch(path_str, "([^%.]+)") do
        table.insert(parts, part)
    end
    local current = tbl
    for _, part in ipairs(parts) do
        if type(current) ~= "table" then
            return nil
        end
        current = current[part]
    end
    return current
end

return M
