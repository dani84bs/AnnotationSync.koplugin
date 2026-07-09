describe("Issue #87 Reproduction: false-positive deletions on PDF pages with multiple highlights", function()
    local annotations_mod

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        annotations_mod = require("annotations")
    end)

    -- Minimal PDF-style position comparator: page number first, then x
    -- within a page (mirrors koptinterface:comparePositions' contract:
    -- returns 1 if pos2 is after pos1, -1 if before, 0 if same).
    local function make_mock_doc()
        return {
            comparePositions = function(self, pos1, pos2)
                if pos1.page ~= pos2.page then
                    return pos1.page < pos2.page and 1 or -1
                end
                if pos1.x == pos2.x then return 0 end
                return pos1.x > pos2.x and -1 or 1
            end
        }
    end

    local function point_annotation(page, x, text)
        local pos = { page = page, x = x, y = 0 }
        return { page = page, pos0 = pos, pos1 = pos, text = text,
                 datetime_updated = "2026-01-01 00:00:00" }
    end

    it("does not mark untouched same-page highlights deleted on a pure no-op sync", function()
        -- Root cause: the inner tie-break in get_deleted_annotations compares
        -- only the coarse .page number, so two distinct highlights on the
        -- same PDF page always tie (cmp == 0). Once the scan pointer matches
        -- the first uploaded entry, it never advances on to check later local
        -- entries against the next uploaded entry -- it bails out on the
        -- first same-page mismatch. This reproduces with NO new highlight,
        -- NO edit, NO deletion: local_map is byte-for-byte identical to
        -- last_uploaded_map.
        local mock_doc = make_mock_doc()

        local u1 = point_annotation(1, 10, "u1")
        local u2 = point_annotation(1, 20, "u2")
        local last_sync_map = {
            [annotations_mod.annotation_key(u1)] = u1,
            [annotations_mod.annotation_key(u2)] = u2,
        }

        local l1 = point_annotation(1, 10, "u1")
        local l2 = point_annotation(1, 20, "u2")
        local local_map = {
            [annotations_mod.annotation_key(l1)] = l1,
            [annotations_mod.annotation_key(l2)] = l2,
        }

        annotations_mod.get_deleted_annotations(local_map, last_sync_map, mock_doc)

        assert.falsy(u1.deleted, "u1 unchanged, must not be marked deleted")
        assert.falsy(u2.deleted, "u2 unchanged, must not be marked deleted (pure no-op sync)")
    end)
end)
