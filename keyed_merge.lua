local M = {}

local function fields_equal(a, b)
    if a == nil or b == nil then
        return a == b
    end
    return a.value == b.value
end

-- Does `record` hold anything `other` doesn't already have (a whole missing
-- record, a missing field, or a differing field value)? Drives `changed`:
-- remote only needs a re-upload when the merged result disagrees with what
-- it currently holds, regardless of which side supplied the winning value.
local function record_differs(record, other)
    if not other then
        return true
    end
    for field_name, field in pairs(record.fields) do
        if not fields_equal(field, other.fields[field_name]) then
            return true
        end
    end
    for field_name in pairs(other.fields) do
        if not record.fields[field_name] then
            return true
        end
    end
    return false
end

-- Reconciles two Extractor Record maps (Merge Key -> record) by applying
-- each field's own declared policy independently. Unlike annotation_sweep's
-- position-based Merge, this has no notion of geometry/ordering -- it's a
-- flat key+field comparison, generalized from remote.lua's settings/progress
-- device-map merge loop.
function M.merge(local_records, incoming_records)
    local merged = {}

    for key, record in pairs(local_records) do
        merged[key] = record
    end

    for key, incoming_record in pairs(incoming_records) do
        local local_record = merged[key]
        if not local_record then
            merged[key] = incoming_record
        else
            local merged_fields = {}
            for field_name, field in pairs(local_record.fields) do
                merged_fields[field_name] = field
            end
            for field_name, incoming_field in pairs(incoming_record.fields) do
                local local_field = merged_fields[field_name]
                if not local_field then
                    -- First write for this field: nothing local to protect.
                    merged_fields[field_name] = incoming_field
                elseif local_field.policy == "last_write_wins"
                    and (incoming_field.changed_at or 0) > (local_field.changed_at or 0) then
                    merged_fields[field_name] = incoming_field
                end
                -- write_once with an existing local value: never overwritten.
                -- A true first-write collision (both sides introduce the
                -- same key/field simultaneously with different values) can't
                -- happen within a single merge call -- "first write" here
                -- always means local had no value yet, so incoming's value
                -- is accepted deterministically. The spec's "deterministic-
                -- but-arbitrary based on merge implementation order" framing
                -- describes this: local always wins once set, purely because
                -- this loop seeds merged_fields from local before looking at
                -- incoming, not because of any designed tiebreak rule.
            end
            merged[key] = { fields = merged_fields }
        end
    end

    local changed = false
    for key, record in pairs(merged) do
        if record_differs(record, incoming_records[key]) then
            changed = true
            break
        end
    end

    return merged, changed
end

return M
