describe("keyed_merge", function()
    local keyed_merge

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        keyed_merge = require("keyed_merge")
    end)

    local function field(value, policy, changed_at)
        return { value = value, policy = policy, changed_at = changed_at }
    end

    it("never overwrites a write_once field with a later incoming value", function()
        local local_records = {
            k1 = { fields = { phrase = field("hola", "write_once", 100) } }
        }
        local incoming_records = {
            k1 = { fields = { phrase = field("adios", "write_once", 200) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("hola", merged.k1.fields.phrase.value)
        assert.is_false(changed)
    end)

    it("accepts a write_once field's first value from incoming when local never set it", function()
        local local_records = {
            k1 = { fields = {} }
        }
        local incoming_records = {
            k1 = { fields = { phrase = field("hola", "write_once", 100) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("hola", merged.k1.fields.phrase.value)
        assert.is_true(changed)
    end)

    -- Accepted edge case (spec): a first-write collision -- both sides
    -- introducing the same key/field with different values -- resolves
    -- deterministically-but-arbitrarily based on merge implementation
    -- order, not a designed tiebreak. This merge always seeds from local
    -- first, so local wins here; that's an artifact of implementation
    -- order, not a correctness guarantee to build on.
    it("resolves a write_once first-write collision by implementation order, not a designed tiebreak", function()
        local local_records = {
            k1 = { fields = { phrase = field("hola", "write_once", 100) } }
        }
        local incoming_records = {
            k1 = { fields = { phrase = field("bonjour", "write_once", 50) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("hola", merged.k1.fields.phrase.value)
        assert.is_false(changed)
    end)

    it("takes the incoming last_write_wins value on strict changed_at >", function()
        local local_records = {
            k1 = { fields = { due = field(1, "last_write_wins", 100) } }
        }
        local incoming_records = {
            k1 = { fields = { due = field(2, "last_write_wins", 200) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal(2, merged.k1.fields.due.value)
        assert.is_true(changed)
    end)

    it("keeps the local last_write_wins value on a changed_at tie, without flapping changed", function()
        local local_records = {
            k1 = { fields = { due = field(1, "last_write_wins", 100) } }
        }
        local incoming_records = {
            k1 = { fields = { due = field(2, "last_write_wins", 100) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal(1, merged.k1.fields.due.value)
        assert.is_false(changed)
    end)

    it("keeps the local last_write_wins value when incoming is older", function()
        local local_records = {
            k1 = { fields = { due = field(1, "last_write_wins", 200) } }
        }
        local incoming_records = {
            k1 = { fields = { due = field(2, "last_write_wins", 100) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal(1, merged.k1.fields.due.value)
        assert.is_false(changed)
    end)

    it("lets two devices independently bump different fields on the same record without clobbering either", function()
        local local_records = {
            k1 = {
                fields = {
                    phrase = field("hola", "write_once", 100),
                    due = field(1, "last_write_wins", 100),
                }
            }
        }
        local incoming_records = {
            k1 = {
                fields = {
                    fsrs_state = field("learning", "last_write_wins", 150),
                }
            }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("hola", merged.k1.fields.phrase.value)
        assert.is_equal(1, merged.k1.fields.due.value)
        assert.is_equal("learning", merged.k1.fields.fsrs_state.value)
        assert.is_true(changed)
    end)

    it("passes through a field present on only the local side untouched", function()
        local local_records = {
            k1 = { fields = { sentence = field("only local", "write_once", 100) } }
        }
        local incoming_records = {
            k1 = { fields = {} }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("only local", merged.k1.fields.sentence.value)
        assert.is_false(changed)
    end)

    it("adds a whole new key present only in incoming", function()
        local local_records = {}
        local incoming_records = {
            k1 = { fields = { phrase = field("hola", "write_once", 100) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("hola", merged.k1.fields.phrase.value)
        assert.is_true(changed)
    end)

    it("keeps a key present only locally untouched", function()
        local local_records = {
            k1 = { fields = { phrase = field("hola", "write_once", 100) } }
        }
        local incoming_records = {}

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_equal("hola", merged.k1.fields.phrase.value)
        assert.is_false(changed)
    end)

    it("reports changed = false when merging two identical record sets", function()
        local local_records = {
            k1 = { fields = { due = field(1, "last_write_wins", 100), phrase = field("hola", "write_once", 100) } }
        }
        local incoming_records = {
            k1 = { fields = { due = field(1, "last_write_wins", 100), phrase = field("hola", "write_once", 100) } }
        }

        local merged, changed = keyed_merge.merge(local_records, incoming_records)

        assert.is_false(changed)
    end)
end)
