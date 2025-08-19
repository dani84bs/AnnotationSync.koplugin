local M = {}

function M.insert_after_statistics(order_table, key)
    local pos = 1
    for index, value in ipairs(order_table.tools) do
        if value == "statistics" then
            pos = index + 1
            break
        end
    end
    table.insert(order_table.tools, pos, key)
end

return M
