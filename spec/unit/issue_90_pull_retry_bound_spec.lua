-- Investigation for GitHub #90's second symptom: pushes/pulls failing
-- ("Fetching remote progress..." -> "Something went wrong") after renaming
-- devices, worse with more devices. #85/#90's confirmed additive-merge bug
-- keeps growing progress.json forever, widening the window for concurrent
-- writers to collide on the WebDAV If-Match ETag (a real 412 conflict, not
-- a bug on its own -- it's meant to be retried).
--
-- Tracing where that retry happens: koreader's two sync-loop implementations
-- have diverged. `apps/cloudstorage/syncservice.lua` (SyncService.sync, used
-- when the Cloud Storage plugin is NOT active) had its If-Match retry loop
-- bounded in koreader commit 213e0220b ("WebDAV sync: fix infinite 412 loop
-- on weak ETags", #15715). `plugins/cloudstorage.koplugin/main.lua`
-- (Cloud:sync, used when the Cloud Storage plugin IS active -- the path
-- `remote.get_sync_provider` prefers, and what most real users hit) still
-- has the original unbounded `while code_response == 412 do ... end` loop.
--
-- This drives both loops directly, with a mock provider/API that always
-- reports a conflict, to check whether that divergence is real.
describe("issue #90: cloud sync retry-loop bound divergence", function()
    local Cloud, SyncService, WebDavApi

    setup(function()
        require("commonrequire")
        Cloud = dofile("plugins/cloudstorage.koplugin/main.lua")
        SyncService = require("apps/cloudstorage/syncservice")
        WebDavApi = require("apps/cloudstorage/webdavapi")
    end)

    local function write_file(path, content)
        local f = io.open(path, "w")
        f:write(content)
        f:close()
    end

    it("Cloud:sync (real cloudstorage.koplugin path) retries a persistent 412 past any internal bound", function()
        local calls = 0
        local cap = 20 -- SyncService's bound is 5; this only needs to exceed that to prove there's no bound here
        Cloud.providers = {
            webdav = {
                run = function(cb) cb() end,
                downloadFile = function(url, local_path)
                    calls = calls + 1
                    if calls > cap then
                        error("UNBOUNDED_RETRY_LOOP: still retrying after " .. cap .. " attempts")
                    end
                    write_file(local_path, "{}")
                    return 200, nil
                end,
                uploadFile = function(url, local_path, etag)
                    return 412 -- persistent conflict, e.g. another device racing the same write
                end,
            },
        }

        local server = { type = "webdav", address = "http://mock", url = "/", username = "u", password = "p" }
        local tmp = os.tmpname()
        write_file(tmp, "{}")

        Cloud:sync(server, tmp, function() return true end, true)

        local ok, err = pcall(fastforward_ui_events)

        os.remove(tmp)
        os.remove(tmp .. ".temp")
        os.remove(tmp .. ".sync")

        assert.is_false(ok, "Cloud:sync stopped retrying on its own -- divergence from syncservice.lua may be fixed")
        assert.truthy(tostring(err):find("UNBOUNDED_RETRY_LOOP"),
            "expected the forced stop, got a different error: " .. tostring(err))
    end)

    it("SyncService.sync (the koreader-fixed sibling) gives up after its bounded number of tries", function()
        local calls = 0
        local old_download = WebDavApi.downloadFile
        local old_upload = WebDavApi.uploadFile

        WebDavApi.downloadFile = function(url, user, pass, local_path)
            calls = calls + 1
            write_file(local_path, "{}")
            return 200, nil
        end
        WebDavApi.uploadFile = function(url, user, pass, local_path, etag)
            return 412 -- same persistent conflict
        end

        local server = { type = "webdav", address = "http://mock", url = "/", username = "u", password = "p" }
        local tmp = os.tmpname()
        write_file(tmp, "{}")

        SyncService.sync(server, tmp, function() return true end, true)

        WebDavApi.downloadFile = old_download
        WebDavApi.uploadFile = old_upload
        os.remove(tmp)
        os.remove(tmp .. ".temp")
        os.remove(tmp .. ".sync")

        assert.is_true(calls <= 5, "expected SyncService's bounded retry (max_tries=5), got " .. calls .. " attempts")
    end)
end)
