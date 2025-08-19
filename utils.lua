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

function M.annotation_key(annotation)
    return annotation.pos0 .. "|" .. annotation.pos1
end

function M.build_annotation_map(annotations)
    local map = {}
    if type(annotations) == "table" then
        for _, ann in ipairs(annotations) do
            local key = M.annotation_key(ann)
            map[key] = ann
        end
    end
    return map
end

return M
