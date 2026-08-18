-- Regression test for GH-90's second symptom (push/pull failing after
-- device rename, worse with more devices): a genuine WebDAV If-Match
-- conflict (two devices racing a write) makes `Cloud:sync` (the real
-- cloudstorage.koplugin path most users hit) retry forever -- confirmed
-- unbounded in issue_90_pull_retry_bound_spec.lua, against koreader's own
-- Cloud:sync. koreader's sibling implementation (SyncService.sync) bounds
-- this to 5 tries, but that fix was never ported to cloudstorage.koplugin,
-- and we don't touch koreader core from this plugin.
--
-- Fix lives on our side of the seam instead: the sync_cb we hand to
-- provider:sync can itself refuse to keep retrying. This drives
-- remote.push_progress/pull_progress against a fake provider that mimics
-- Cloud:sync's retry loop (call sync_cb again as long as it returns true;
-- stop the moment it returns false) to prove our callback gives up after a
-- bounded number of attempts instead of feeding the real loop forever.
describe("issue #90: bounded give-up on a persistent sync conflict", function()
    local remote, utils

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        remote = require("remote")
        utils = require("utils")
    end)

    -- Mimics Cloud:sync's retry loop shape: every iteration it downloads
    -- (always "succeeds" here) then calls sync_cb; a persistent conflict
    -- means the *upload* after a true return would 412 and loop back, so
    -- each true return just drives another iteration. A false return is
    -- exactly the "give up" signal Cloud:sync's `not cb_return` branch acts
    -- on. `hard_cap` is a test-only safety net, not the behavior under test:
    -- without a fix, calls will run away until it, proving there's no bound.
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

    it("push_progress gives up after a bounded number of attempts, not indefinitely", function()
        local state = { calls = 0 }
        local widget = make_widget(persistent_conflict_provider(state, 1000))
        local json_path = os.tmpname()
        seed_local_file(json_path)

        local old_show_msg = utils.show_msg
        local shown = {}
        utils.show_msg = function(msg) table.insert(shown, msg) end

        remote.push_progress(widget, json_path, function() end)

        utils.show_msg = old_show_msg
        os.remove(json_path)
        os.remove(json_path .. ".temp")
        os.remove(json_path .. ".sync")

        assert.is_true(state.calls < 1000, "push_progress fed the retry loop indefinitely: " .. state.calls .. " attempts")
        assert.is_true(state.calls <= 6, "expected a small bounded number of attempts, got " .. state.calls)

        local found_conflict_msg = false
        for _, msg in ipairs(shown) do
            if tostring(msg):lower():find("conflict") then found_conflict_msg = true end
        end
        assert.is_true(found_conflict_msg, "expected a distinct conflict message on give-up, got: " .. table.concat(shown, " | "))
    end)

    it("pull_progress gives up after a bounded number of attempts, not indefinitely", function()
        local state = { calls = 0 }
        local widget = make_widget(persistent_conflict_provider(state, 1000))
        local json_path = os.tmpname()
        seed_local_file(json_path)

        local old_show_msg = utils.show_msg
        local shown = {}
        utils.show_msg = function(msg) table.insert(shown, msg) end

        remote.pull_progress(widget, json_path, function() end)

        utils.show_msg = old_show_msg
        os.remove(json_path)
        os.remove(json_path .. ".temp")
        os.remove(json_path .. ".sync")

        assert.is_true(state.calls < 1000, "pull_progress fed the retry loop indefinitely: " .. state.calls .. " attempts")
        assert.is_true(state.calls <= 6, "expected a small bounded number of attempts, got " .. state.calls)

        local found_conflict_msg = false
        for _, msg in ipairs(shown) do
            if tostring(msg):lower():find("conflict") then found_conflict_msg = true end
        end
        assert.is_true(found_conflict_msg, "expected a distinct conflict message on give-up, got: " .. table.concat(shown, " | "))
    end)
end)
