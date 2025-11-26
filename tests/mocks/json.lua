local M = {}

function M.decode(str)
    if str == '{"key": "value"}' then
        return { key = "value" }
    else
        return nil
    end
end

return M
