-- E2E: hash-based sync-filename mode (`use_filename = false`, the actual
-- production default -- every other e2e spec explicitly overrides it to
-- true), over a real local WebDAV server.
--
-- Pins two things unit tests can't: the remote object is named by
-- `util.partialMD5(file)`, not by basename, and a highlight survives a
-- local rename -- rename/move survival being the documented purpose of
-- hash mode. EPUB only: the behavior under test is filename resolution /
-- remote naming, which is format-agnostic.
describe("AnnotationSync E2E hash-based filename mode", function()
    local Event, UIManager, changed_documents, util, WebDavApi, json
    local AnnotationSyncPlugin, test_utils, e2e_test_utils, annotations_key

    local function fresh_copy(test_data_dir, name, source)
        local dest = test_data_dir .. "/" .. name
        require("ffi/util").copyFile(source, dest)
        return dest
    end

    local function boot(test_data_dir, file)
        local old_getDataDir = test_utils.setup_test_env(test_data_dir)
        local old_ImageViewer_new = test_utils.mock_image_viewer()

        local readerui, sync_instance = e2e_test_utils.init_real_remote_context(
            file, AnnotationSyncPlugin
        )
        UIManager:show(readerui)
        fastforward_ui_events()
        sync_instance.settings.last_sync = "Never"
        os.remove(changed_documents.path())

        return readerui, sync_instance, old_getDataDir, old_ImageViewer_new
    end

    -- Closes the ReaderUI without wiping test_data_dir: the rename scenario
    -- keeps device A's and device B's boots in the same directory, unlike
    -- teardown_test_env (used only on the final boot) which rm -rf's it.
    local function close_reader(readerui)
        readerui:onClose()
        UIManager:quit()
        package.loaded["main"] = nil
    end

    local function teardown(test_data_dir, readerui, old_getDataDir, old_ImageViewer_new)
        readerui:onClose()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
        require("ui/widget/imageviewer").new = old_ImageViewer_new
        UIManager:quit()
        package.loaded["main"] = nil
    end

    -- Downloads the annotation map from the WebDAV path named by `hash`
    -- directly, independent of `_getAnnotationFilename` -- so the
    -- assertion actually pins remote naming rather than just proving the
    -- same function agrees with itself.
    local function fetch_by_hash(hash, test_data_dir)
        local server = e2e_test_utils.server_config()
        local remote_path = WebDavApi:getJoinedPath(server.address, server.url)
        remote_path = WebDavApi:getJoinedPath(remote_path, hash .. ".json")

        local tmp_path = test_data_dir .. "/.fetch_by_hash.json"
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
        if not ok then return nil, code end
        return data, code
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        disable_plugins()
        require("document/canvascontext"):init(require("device"))
        Event = require("ui/event")
        UIManager = require("ui/uimanager")
        changed_documents = require("changed_documents")
        util = require("util")
        WebDavApi = require("apps/cloudstorage/webdavapi")
        json = require("json")

        test_utils = require("spec/unit/test_utils")
        e2e_test_utils = require("spec/e2e/e2e_test_utils")
        AnnotationSyncPlugin = require("main")
        annotations_key = require("annotations").annotation_key
    end)

    it("names the remote object by hash and survives a local rename", function()
        local highlight_db = require("spec/unit/highlight_db")
        local test_data_dir = os.getenv("PWD") .. "/test_e2e_hash_filename_mode_tmp"
        os.execute("mkdir -p " .. test_data_dir)
        local file_a = fresh_copy(test_data_dir, "hash-mode-a.epub", "spec/front/unit/data/juliet.epub")

        local readerui_a, sync_instance_a = boot(test_data_dir, file_a)
        assert.is_false(sync_instance_a.settings.use_filename)

        readerui_a.rolling:onGotoPage(3)
        fastforward_ui_events()
        test_utils.emulate_highlight(readerui_a, highlight_db[1])
        assert.is_equal(1, #readerui_a.annotation.annotations)
        local uploaded_key = annotations_key(readerui_a.annotation.annotations[1])

        local hash = util.partialMD5(file_a)
        assert.is_equal(hash .. ".json", sync_instance_a.manager:_getAnnotationFilename(file_a))

        readerui_a:handleEvent(Event:new("AnnotationSyncManualSync"))

        local remote_by_hash, fetch_code = fetch_by_hash(hash, test_data_dir)
        assert.is_true(fetch_code ~= nil and fetch_code >= 200 and fetch_code < 300)
        assert.is_not_nil(remote_by_hash)
        assert.is_not_nil(remote_by_hash[uploaded_key])

        close_reader(readerui_a)

        -- Same content, new local filename -- KOReader's book-identity hash
        -- (util.partialMD5 samples file content, not the path) stays the
        -- same, so the rename must resolve to the same remote object.
        local file_b = test_data_dir .. "/hash-mode-b.epub"
        os.rename(file_a, file_b)
        assert.is_equal(hash, util.partialMD5(file_b))

        local readerui_b, _, old_getDataDir_b, old_ImageViewer_b = boot(test_data_dir, file_b)
        assert.is_equal(0, #readerui_b.annotation.annotations)

        readerui_b:handleEvent(Event:new("AnnotationSyncManualSync"))

        assert.is_equal(1, #readerui_b.annotation.annotations)
        assert.is_equal(uploaded_key, annotations_key(readerui_b.annotation.annotations[1]))

        teardown(test_data_dir, readerui_b, old_getDataDir_b, old_ImageViewer_b)
    end)
end)
