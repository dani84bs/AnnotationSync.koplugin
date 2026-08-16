-- Real-remote boot helper: adapts spec/unit/test_utils.lua's
-- setup_test_env/init_integration_context pattern to point cloud storage
-- config at a real local WebDAV server (started by run_e2e_tests.sh)
-- instead of the mocked "http://mock-server" the unit-level integration
-- specs use.
local json = require("json")
local test_utils = require("spec/unit/test_utils")

local M = {}

M.webdav = {
    host = os.getenv("ANNOTATIONSYNC_E2E_WEBDAV_HOST") or "127.0.0.1",
    port = tonumber(os.getenv("ANNOTATIONSYNC_E2E_WEBDAV_PORT")) or 18109,
    username = os.getenv("ANNOTATIONSYNC_E2E_WEBDAV_USERNAME") or "testuser",
    password = os.getenv("ANNOTATIONSYNC_E2E_WEBDAV_PASSWORD") or "testpass",
}

function M.server_config()
    return {
        type = "webdav",
        address = string.format("http://%s:%d", M.webdav.host, M.webdav.port),
        url = "/",
        username = M.webdav.username,
        password = M.webdav.password,
    }
end

-- Points G_reader_settings at the real WebDAV server, the same keys
-- AnnotationSyncPlugin:onSyncServiceConfirm persists in production.
function M.configure_real_remote()
    local server = M.server_config()
    G_reader_settings:saveSetting("cloud_download_dir", server.address)
    G_reader_settings:saveSetting("cloud_server_object", json.encode(server))
    G_reader_settings:saveSetting("cloud_provider_type", server.type)
    return server
end

-- Boots a real ReaderUI + AnnotationSyncPlugin wired to the real WebDAV
-- server: skips test_utils' automatic SyncService mock so
-- AnnotationSyncManualSync/AnnotationSyncSyncAll drive an actual HTTP
-- round-trip via remote.lua's SyncServiceAdapter.
function M.init_real_remote_context(file, AnnotationSyncPlugin)
    local readerui, sync_instance = test_utils.init_integration_context(
        file, AnnotationSyncPlugin, { skip_sync_mock = true }
    )
    sync_instance.settings.sync_server = M.configure_real_remote()
    return readerui, sync_instance
end

-- Seeds the real WebDAV server with an annotation map for `file`, at the
-- same path SyncService.sync will download from -- simulating a prior
-- sync from another device without actually running a second device.
function M.seed_remote_annotations(sync_instance, file, data, test_data_dir)
    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local server = M.server_config()
    local file_name = sync_instance.manager:_getAnnotationFilename(file)
    local remote_path = WebDavApi:getJoinedPath(server.address, server.url)
    remote_path = WebDavApi:getJoinedPath(remote_path, file_name)

    local tmp_path = test_data_dir .. "/.seed_remote.json"
    local encoded = json.encode(data)
    if encoded == "[]" then encoded = "{}" end
    local f = io.open(tmp_path, "w")
    f:write(encoded)
    f:close()

    local code = WebDavApi:uploadFile(remote_path, server.username, server.password, tmp_path)
    os.remove(tmp_path)
    return code
end

-- Downloads and decodes the annotation map currently stored for `file` on
-- the real WebDAV server -- the inverse of seed_remote_annotations, used
-- to inspect what a sync actually persisted remotely.
function M.fetch_remote_annotations(sync_instance, file, test_data_dir)
    local WebDavApi = require("apps/cloudstorage/webdavapi")
    local server = M.server_config()
    local file_name = sync_instance.manager:_getAnnotationFilename(file)
    local remote_path = WebDavApi:getJoinedPath(server.address, server.url)
    remote_path = WebDavApi:getJoinedPath(remote_path, file_name)

    local tmp_path = test_data_dir .. "/.fetch_remote.json"
    local code = WebDavApi:downloadFile(remote_path, server.username, server.password, tmp_path)
    if not code or code < 200 or code >= 300 then
        os.remove(tmp_path)
        return nil, code
    end

    local f = io.open(tmp_path, "r")
    local content = f:read("*a")
    f:close()
    os.remove(tmp_path)

    local ok, data = pcall(json.decode, content)
    if not ok then
        return nil, code
    end
    return data, code
end

return M
