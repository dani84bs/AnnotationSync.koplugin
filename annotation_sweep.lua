local M = {}

function M.is_annotation(candidate)
    return candidate and candidate.pos0 and candidate.pos1
end

function M.is_bookmark(candidate)
    return candidate and candidate.page and not M.is_annotation(candidate)
end

-- Generates a unique key based on geometry or page
function M.annotation_key(annotation)
    if M.is_annotation(annotation) then
        local p0 = ""
        local p1 = ""
        if type(annotation.pos0) == "table" then
            local zoom = annotation.pos0.zoom or 1
            local page = annotation.page or annotation.pos0.page or 0
            p0 = string.format("%d|%d|%d", page, math.floor(annotation.pos0.x / zoom), math.floor(annotation.pos0.y / zoom))
            p1 = string.format("%d|%d", math.floor(annotation.pos1.x / zoom), math.floor(annotation.pos1.y / zoom))
        else
            p0 = annotation.pos0
            p1 = annotation.pos1
        end
        return p0 .. "||" .. p1
    elseif M.is_bookmark(annotation) then
        return "BOOKMARK|" .. tostring(annotation.page)
    end
end

-- Universal comparison logic for various annotation position types
function M.compare_positions(a, b, document)
    if not a or not b then return 0 end
    if type(a) == "number" and type(b) == "number" then
        if a < b then return -1 end
        if a > b then return 1 end
        return 0
    end
    if type(a) == "string" and type(b) == "string" then
        local cmp = document:compareXPointers(a, b)
        return cmp and -cmp or 0
    end
    if type(a) == "table" and type(b) == "table" then
        local cmp = document:comparePositions(a, b)
        return cmp and -cmp or 0
    end
    -- Fallback for mixed types
    return 0
end

function M.positions_intersect(a, b, document)
    if not a or not b then
        return false
    end

    if M.annotation_key(a) == M.annotation_key(b) then
        return true
    end

    if not a.pos0 or not a.pos1 or not b.pos0 or not b.pos1 then
        return false
    end

    local c1 = M.compare_positions(a.pos0, b.pos0, document)
    local c2 = M.compare_positions(b.pos0, a.pos1, document)
    local c3 = M.compare_positions(b.pos0, a.pos0, document)
    local c4 = M.compare_positions(a.pos0, b.pos1, document)

    -- A_Start <= B_Start <= A_End
    if c1 <= 0 and c2 <= 0 then
        return true
    end

    -- B_Start <= A_Start <= B_End
    if c3 <= 0 and c4 <= 0 then
        return true
    end

    return false
end

function M.sort_keys_by_position(t, document)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        local ann_a = t[a]
        local ann_b = t[b]
        local pos_a = ann_a.pos0 or ann_a.page
        local pos_b = ann_b.pos0 or ann_b.page
        local cmp = M.compare_positions(pos_a, pos_b, document)
        return (cmp or 0) < 0
    end)
    return keys
end

function M.is_before(a, b)
    local a_time = a.datetime_updated or a.datetime or 0
    local b_time = b.datetime_updated or b.datetime or 0
    return a_time <= b_time
end

local function deep_equal(a, b)
    if a == b then return true end
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for k, v in pairs(a) do
        if not deep_equal(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- True when both annotation lists hold the same entries by key and content,
-- order aside -- used to skip notifying the rest of the system about a
-- merge that changed nothing.
function M.lists_equal(list_a, list_b)
    if #list_a ~= #list_b then return false end
    local map_a, map_b = {}, {}
    for _, ann in ipairs(list_a) do map_a[M.annotation_key(ann)] = ann end
    for _, ann in ipairs(list_b) do map_b[M.annotation_key(ann)] = ann end
    for k, v in pairs(map_a) do
        if not deep_equal(v, map_b[k]) then return false end
    end
    for k in pairs(map_b) do
        if map_a[k] == nil then return false end
    end
    return true
end

-- Marks entries in uploaded_map as deleted when no local annotation still
-- overlaps their position. A single local annotation may satisfy (keep
-- alive) several uploaded entries, so matches never advance the floor --
-- only a *proven* non-match does.
function M.find_deleted(local_map, uploaded_map, document)
    local local_keys = M.sort_keys_by_position(local_map, document)
    local uploaded_keys = M.sort_keys_by_position(uploaded_map, document)

    -- `l` is a persistent floor: local entries before it have been proven
    -- to end strictly before the CURRENT uploaded entry's start, so they
    -- can never match this or any later (higher-sorted) uploaded entry
    -- either, and are permanently skipped. Matches never advance `l`, so
    -- a single wide local annotation can still satisfy several uploaded
    -- entries (Issue #69).
    --
    -- For each uploaded entry, `j` walks forward from `l` looking for a
    -- match. Crucially this uses the fine-grained pos0/pos1 range (via
    -- positions_intersect/compare_positions), not the coarse `.page`
    -- number: two distinct highlights routinely share the same PDF page
    -- number, which made the old page-only check tie (0) on the very
    -- first non-matching same-page candidate and give up immediately,
    -- wrongly marking every later same-page uploaded entry as deleted
    -- (Issue #87).
    local l = 1
    for _, uploaded_k in ipairs(uploaded_keys) do
        local uploaded_v = uploaded_map[uploaded_k]
        local uploaded_start = uploaded_v.pos0 or uploaded_v.page
        local matched = false
        local j = l
        while j <= #local_keys do
            local local_v = local_map[local_keys[j]]
            if M.positions_intersect(uploaded_v, local_v, document) then
                matched = true
                break
            end
            -- Only permanently discard local_v when it's STRICTLY before
            -- uploaded_v's start (compare < 0). A tie (0) is ambiguous: it
            -- may mean "same position", but compare_positions also
            -- collapses an unresolvable/invalid XPointer comparison (nil
            -- from document:compareXPointers, e.g. a stale annotation
            -- position) into 0. Treating that as "safe to discard" could
            -- silently mark a still-present annotation as deleted, so
            -- ties fall through to stop the lookahead instead, keeping
            -- local_v available for re-examination against later
            -- uploaded entries.
            local local_end = local_v.pos1 or local_v.page
            if M.compare_positions(local_end, uploaded_start, document) < 0 then
                j = j + 1
                l = j
            else
                break
            end
        end
        if not matched then
            uploaded_v.deleted = true
            uploaded_v.datetime_updated = os.date("%Y-%m-%d %H:%M:%S")
            local_map[uploaded_k] = uploaded_v
        end
    end
end

-- Consuming merge of local and incoming annotation maps: each position slot
-- is filled exactly once, taking whichever side is newer on overlap (via
-- is_before) or whichever sorts earlier on a gap.
function M.merge(local_map, income_map, document)
    local merged = {}
    local local_keys = M.sort_keys_by_position(local_map, document)
    local income_keys = M.sort_keys_by_position(income_map, document)
    local l = 1
    local i = 1

    while i <= #income_keys and l <= #local_keys do
        local income_k = income_keys[i]
        local local_k = local_keys[l]
        local income_v = income_map[income_k]
        local local_v = local_map[local_k]

        if M.positions_intersect(income_v, local_v, document) then
            if M.is_before(income_v, local_v) then
                merged[local_k] = local_v
            else
                merged[income_k] = income_v
            end
            i = i + 1
            l = l + 1
        else
            local local_p = local_v.pos0 or local_v.page
            local income_p = income_v.pos0 or income_v.page
            local cmp = M.compare_positions(local_p, income_p, document)
            if (cmp or 0) < 0 then
                merged[local_k] = local_v
                l = l + 1
            else
                merged[income_k] = income_v
                i = i + 1
            end
        end
    end

    while l <= #local_keys do
        local local_k = local_keys[l]
        merged[local_k] = local_map[local_k]
        l = l + 1
    end

    while i <= #income_keys do
        local income_k = income_keys[i]
        merged[income_k] = income_map[income_k]
        i = i + 1
    end

    return merged
end

return M
