describe("annotation_sweep", function()
    local sweep
    local bit = require("bit")

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        sweep = require("annotation_sweep")
    end)

    -- Closed-interval overlap, independent of positions_intersect's own
    -- implementation: [s1,e1] and [s2,e2] overlap iff s1 <= e2 and s2 <= e1.
    -- Touching endpoints count as overlap (matches positions_intersect's
    -- <=0 tie handling).
    local function intervals_overlap(a, b)
        return a.pos0 <= b.pos1 and b.pos0 <= a.pos1
    end

    local function make_entry(id, s, e)
        return { id = id, pos0 = s, pos1 = e, page = s, datetime_updated = "2026-01-01 00:00:00" }
    end

    -- A small base set of interval shapes chosen to cover: a point, a wide
    -- range, and two entries whose boundaries tie (touch) each other --
    -- exactly the configurations the Issue #69/#87 fixes were about.
    local BASE = {
        make_entry("A", 1, 3),  -- narrow
        make_entry("B", 2, 2),  -- point, inside A
        make_entry("C", 3, 6),  -- wide, tie-touches A's end
        make_entry("D", 8, 8),  -- point, disjoint from A/B/C
    }

    local function subset(mask)
        local entries = {}
        for i, entry in ipairs(BASE) do
            if bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then
                table.insert(entries, entry)
            end
        end
        return entries
    end

    local function to_map(entries, prefix)
        local map = {}
        for i, e in ipairs(entries) do
            -- Fresh copies: find_deleted mutates uploaded entries in place,
            -- and BASE entries are shared across every generated case.
            map[prefix .. i] = { id = e.id, pos0 = e.pos0, pos1 = e.pos1, page = e.page,
                                  datetime_updated = e.datetime_updated }
        end
        return map
    end

    it("marks an uploaded entry deleted iff no local entry overlaps it, across all local/uploaded combinations", function()
        -- Enumerate every combination of the 4 base shapes for BOTH sides
        -- (16 x 16 = 256 cases). This exercises the floor-pointer reuse
        -- (one local entry surviving several uploaded entries) and the
        -- tie/stop-lookahead behavior generatively instead of via one-off
        -- hand-picked examples.
        for local_mask = 0, 15 do
            for uploaded_mask = 0, 15 do
                local local_entries = subset(local_mask)
                local uploaded_entries = subset(uploaded_mask)

                local local_map = to_map(local_entries, "l")
                local uploaded_map = to_map(uploaded_entries, "u")

                -- Snapshot expectations against the PRE-sweep local_map:
                -- find_deleted writes deleted tombstones back into
                -- local_map, so checking post-sweep would let a just-added
                -- tombstone "overlap itself".
                local expected_survives_by_key = {}
                for key, uploaded_v in pairs(uploaded_map) do
                    local expected_survives = false
                    for _, local_v in pairs(local_map) do
                        if intervals_overlap(uploaded_v, local_v) then
                            expected_survives = true
                            break
                        end
                    end
                    expected_survives_by_key[key] = expected_survives
                end

                sweep.find_deleted(local_map, uploaded_map, nil)

                for key, uploaded_v in pairs(uploaded_map) do
                    local actually_survives = not uploaded_v.deleted
                    assert.are.equal(expected_survives_by_key[key], actually_survives,
                        string.format("local_mask=%d uploaded_mask=%d entry=%s(%d..%d) expected survives=%s got=%s",
                            local_mask, uploaded_mask, uploaded_v.id, uploaded_v.pos0, uploaded_v.pos1,
                            tostring(expected_survives_by_key[key]), tostring(actually_survives)))
                end
            end
        end
    end)

    it("lets one wide local entry keep multiple uploaded entries alive at once", function()
        local local_map = to_map({ make_entry("wide", 0, 20) }, "l")
        local uploaded_map = to_map({
            make_entry("u1", 1, 1),
            make_entry("u2", 10, 10),
            make_entry("u3", 19, 19),
        }, "u")

        sweep.find_deleted(local_map, uploaded_map, nil)

        for key, v in pairs(uploaded_map) do
            assert.falsy(v.deleted, key .. " should be kept alive by the single wide local entry")
        end
    end)

    it("does not let a tie between an unresolved local entry and the current uploaded start hide a later local match", function()
        -- Regression shape for Issue #87: a tie (compare == 0) must stop the
        -- lookahead rather than being treated as "safe to discard".
        local local_map = to_map({
            make_entry("tie", 5, 5),
            make_entry("match", 6, 9),
        }, "l")
        local uploaded_map = to_map({ make_entry("u", 6, 6) }, "u")

        sweep.find_deleted(local_map, uploaded_map, nil)

        for _, v in pairs(uploaded_map) do
            assert.falsy(v.deleted, "uploaded entry overlapping the second local entry must survive")
        end
    end)

    describe("merge", function()
        it("consumes a local entry on its first overlap match; a later overlapping income entry is kept separately", function()
            -- Unlike find_deleted, merge is a strict consuming pass: once
            -- "wide" is paired with i1 (the first income entry it meets),
            -- the local pointer advances past it. i2 -- which positionally
            -- also overlaps "wide" -- is never re-checked against it and is
            -- kept as its own entry. This is the real (pre-existing)
            -- single-pass behavior, not a full N:1 dedup like find_deleted.
            local local_map = to_map({ make_entry("wide", 0, 20) }, "l")
            local income_map = to_map({
                make_entry("i1", 1, 1),
                make_entry("i2", 10, 10),
            }, "i")

            local merged = sweep.merge(local_map, income_map, nil)

            local count = 0
            for _ in pairs(merged) do count = count + 1 end
            assert.are.equal(2, count, "i1 consumes wide via tiebreak; i2 is kept as its own unmerged entry")
        end)

        it("keeps every non-overlapping entry from both sides", function()
            local local_map = to_map({ make_entry("l1", 1, 1) }, "l")
            local income_map = to_map({ make_entry("i1", 10, 10) }, "i")

            local merged = sweep.merge(local_map, income_map, nil)

            local count = 0
            for _ in pairs(merged) do count = count + 1 end
            assert.are.equal(2, count)
        end)
    end)
end)
