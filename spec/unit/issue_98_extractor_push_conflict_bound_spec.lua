-- Regression test for gh-98: push_extractor_data was the only one of
-- remote.lua's four provider:sync call sites that handed sync_cb straight
-- through, unbounded -- see issue_90_persistent_conflict_bound_spec.lua for
-- why that loop needs a caller-side cap in the first place.
describe("issue #98: push_extractor_data bounds its conflict retries", function()
    local remote, utils

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        remote = require("remote")
        utils = require("utils")
    end)

    local function persistent_conflict_provider(state, hard_cap)
        return {
            sync = function(_, server, json_path, sync_cb, is_silent)
                for i = 1, hard_cap do
                    state.calls = i
                    local f = io.open(json_path .. ".temp", "w")
                    f:write("{}")
                    f:close()
                    local cb_return = sync_cb(json_path, json_path .. ".sync", json_path .. ".temp")
                    if not cb_return then
                        return false
                    end
                end
                return false
            end,
        }
    end

    local function make_widget(provider)
        return {
            ui = { cloudstorage = provider },
            settings = { sync_server = { type = "webdav", address = "http://mock", url = "/" } },
        }
    end

    local function seed_local_file(path)
        local f = io.open(path, "w")
        f:write("{}")
        f:close()
    end

    it("gives up after a bounded number of attempts, not indefinitely", function()
        local state = { calls = 0 }
        local widget = make_widget(persistent_conflict_provider(state, 1000))
        local json_path = os.tmpname()
        seed_local_file(json_path)

        local old_show_msg = utils.show_msg
        local shown = {}
        utils.show_msg = function(msg) table.insert(shown, msg) end

        local attempted = remote.push_extractor_data(widget, json_path, function() return true end)

        utils.show_msg = old_show_msg
        os.remove(json_path)
        os.remove(json_path .. ".temp")
        os.remove(json_path .. ".sync")

        assert.is_true(attempted)
        assert.is_true(state.calls < 1000, "push_extractor_data fed the retry loop indefinitely: " .. state.calls .. " attempts")
        assert.is_true(state.calls <= 6, "expected a small bounded number of attempts, got " .. state.calls)

        local found_conflict_msg = false
        for _, msg in ipairs(shown) do
            if tostring(msg):lower():find("conflict") then found_conflict_msg = true end
        end
        assert.is_true(found_conflict_msg, "expected a distinct conflict message on give-up, got: " .. table.concat(shown, " | "))
    end)
end)
