-- Repro for #90/#91's "Something went wrong" sync failure that clears up
-- as soon as the user re-picks the same Dropbox folder.
--
-- koreader's DropBox.genAccessToken() (cloudstorage.koplugin/providers/dropbox.lua)
-- exchanges the long-lived refresh token for a short-lived (4h) access token
-- exactly once, then flips `base.username = true` so it never refreshes
-- again for the lifetime of that `base` table -- it overwrites
-- `base.password` in place with the short-lived token. Cloud:sync sets
-- `provider.base = server` where `server` is whatever table the caller
-- handed it, so this mutates the caller's table directly, not a copy.
--
-- remote.lua hands `widget.settings.sync_server` -- AnnotationSync's own
-- persisted settings table -- straight to `provider:sync` on every push/pull.
-- That table lives for the plugin's whole process lifetime, so the same
-- mutation-in-place corrupts it permanently: after the first sync, the
-- refresh token in settings is gone, replaced by a short-lived token that
-- silently expires a few hours later with every subsequent sync 401ing
-- forever after -- matching "works for a while, then fails" and "re-picking
-- the folder (which builds a fresh table) fixes it".
local function dropbox_like_provider(state)
    return {
        sync = function(_, server, json_path, sync_cb, is_silent)
            -- Mirrors Cloud:sync: provider.base = server (alias, not a copy).
            local base = server

            if base.username or base.address == nil or base.address == "" then
                -- Mirrors DropBox.genAccessToken(): once username is set,
                -- reuse the cached access token unconditionally -- no
                -- expiry check. If it has expired, Dropbox 401s.
                if state.access_token_expired then
                    return false -- Cloud:sync: non-200 download -> show_msg(); return
                end
            else
                -- A fresh refresh-token exchange always yields a valid,
                -- not-yet-expired access token.
                state.refreshes = (state.refreshes or 0) + 1
                base.password = "short-lived-token-" .. state.refreshes
                base.username = true
            end

            local f = io.open(json_path .. ".temp", "w")
            f:write("{}")
            f:close()
            local ok = sync_cb(json_path, json_path .. ".sync", json_path .. ".temp")
            return ok
        end,
    }
end

describe("issue #90/#91: Dropbox refresh token corrupted by in-place base mutation", function()
    local remote, utils

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        remote = require("remote")
        utils = require("utils")
    end)

    local function seed_local_file(path)
        local f = io.open(path, "w")
        f:write("{}")
        f:close()
    end

    it("wipes the persisted refresh token after the very first sync", function()
        local state = {}
        local sync_server = { type = "dropbox", password = "REFRESH_TOKEN", address = "KEY:SECRET" }
        local widget = { ui = { cloudstorage = dropbox_like_provider(state) }, settings = { sync_server = sync_server } }
        local json_path = os.tmpname()
        seed_local_file(json_path)

        remote.push_progress(widget, json_path, function() end)

        os.remove(json_path)
        os.remove(json_path .. ".temp")
        os.remove(json_path .. ".sync")

        -- AnnotationSync's own persisted settings must still hold the
        -- refresh token the user configured, not whatever short-lived
        -- access token the provider generated from it.
        assert.are.equal("REFRESH_TOKEN", sync_server.password)
    end)

    it("fails every sync forever once the cached access token expires, with no way to recover it", function()
        local state = {}
        local sync_server = { type = "dropbox", password = "REFRESH_TOKEN", address = "KEY:SECRET" }
        local widget = { ui = { cloudstorage = dropbox_like_provider(state) }, settings = { sync_server = sync_server } }
        local json_path = os.tmpname()
        seed_local_file(json_path)

        local old_show_msg = utils.show_msg
        local shown = {}
        utils.show_msg = function(msg) table.insert(shown, msg) end

        -- First sync: succeeds, but silently swaps the refresh token in
        -- settings for a short-lived access token (see test above).
        local first_result
        remote.push_progress(widget, json_path, function(success) first_result = success end)
        assert.is_true(first_result)

        -- Hours later: the cached access token has expired. genAccessToken
        -- never re-checks (username is already true), so every subsequent
        -- sync reuses the dead token and 401s.
        state.access_token_expired = true

        local second_result
        remote.push_progress(widget, json_path, function(success) second_result = success end)

        utils.show_msg = old_show_msg
        os.remove(json_path)
        os.remove(json_path .. ".temp")
        os.remove(json_path .. ".sync")

        -- A stale cached access token must not sink every sync from here
        -- on: AnnotationSync should be forcing a fresh refresh-token
        -- exchange per sync rather than reusing whatever token the
        -- provider cached on its first call.
        assert.is_true(second_result)
    end)
end)
