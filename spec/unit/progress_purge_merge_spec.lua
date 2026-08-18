describe("Purge device from progress sync (gh-90)", function()
    local remote, test_utils, json
    local test_data_dir = os.getenv("PWD") .. "/test_progress_purge_tmp"
    local old_getDataDir

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        remote = require("remote")
        test_utils = require("spec/unit/test_utils")
        json = require("json")

        old_getDataDir = test_utils.setup_test_env(test_data_dir)
    end)

    teardown(function()
        test_utils.teardown_test_env(test_data_dir, old_getDataDir)
    end)

    local function run(widget, local_data, income_data)
        local local_path = test_utils.write_mock_json(test_data_dir, "local.json", local_data)
        local last_sync_path = test_utils.write_mock_json(test_data_dir, "last.json", {})
        local income_path = test_utils.write_mock_json(test_data_dir, "income.json", income_data)
        return remote._sync_progress_callback(widget, local_path, last_sync_path, income_path)
    end

    it("removes a device when income carries removed=true with a newer timestamp", function()
        local ok, merged = run({ settings = {} },
            { DeviceA = { page = 5, timestamp = "2026-01-01 00:00:00" } },
            { DeviceA = { removed = true, timestamp = "2026-01-02 00:00:00" } })
        assert.is_true(ok)
        assert.is_true(merged.DeviceA.removed)
    end)

    it("un-removes a device when a newer removed=false beats an older removed=true", function()
        local ok, merged = run({ settings = {} },
            { DeviceA = { removed = true, timestamp = "2026-01-01 00:00:00" } },
            { DeviceA = { removed = false, timestamp = "2026-01-02 00:00:00" } })
        assert.is_true(ok)
        assert.is_false(merged.DeviceA.removed)
    end)

    it("a genuinely newer real progress push overrides an older removed=true record", function()
        local ok, merged = run({ settings = {} },
            { DeviceA = { removed = true, timestamp = "2026-01-01 00:00:00" } },
            { DeviceA = { page = 42, percentage = 0.5, timestamp = "2026-01-02 00:00:00" } })
        assert.is_true(ok)
        assert.is_nil(merged.DeviceA.removed)
        assert.is_equal(42, merged.DeviceA.page)
    end)

    it("does not let an older removed=true income record clobber a newer local record", function()
        local ok, merged = run({ settings = {} },
            { DeviceA = { page = 5, timestamp = "2026-01-02 00:00:00" } },
            { DeviceA = { removed = true, timestamp = "2026-01-01 00:00:00" } })
        assert.is_true(ok)
        assert.is_nil(merged.DeviceA.removed)
        assert.is_equal(5, merged.DeviceA.page)
    end)

    it("resolves two devices purging/un-purging independently with no race", function()
        local ok, merged = run({ settings = {} },
            {
                DeviceA = { page = 1, timestamp = "2026-01-01 00:00:00" },
                DeviceB = { removed = true, timestamp = "2026-01-01 00:00:00" },
            },
            {
                DeviceA = { removed = true, timestamp = "2026-01-02 00:00:00" },
                DeviceB = { removed = false, timestamp = "2026-01-02 00:00:00" },
            })
        assert.is_true(ok)
        assert.is_true(merged.DeviceA.removed)
        assert.is_false(merged.DeviceB.removed)
    end)

    it("writes a fresh removed=true tombstone for a purged_devices entry with no prior record", function()
        local ok, merged = run({ settings = { purged_devices = { "RetiredDevice" } } }, {}, {})
        assert.is_true(ok)
        assert.is_true(merged.RetiredDevice.removed)
        assert.is_not_nil(merged.RetiredDevice.timestamp)
    end)

    it("stamps down an existing real record for a purged_devices entry, dropping page/pos", function()
        local ok, merged = run({ settings = { purged_devices = { "DeviceA" } } },
            { DeviceA = { page = 5, percentage = 0.5, pos = "abc", timestamp = "2026-01-01 00:00:00" } },
            {})
        assert.is_true(ok)
        assert.is_true(merged.DeviceA.removed)
        assert.is_nil(merged.DeviceA.page)
        assert.is_nil(merged.DeviceA.pos)
    end)

    it("does not re-stamp a device already removed=true from purged_devices", function()
        local ok, merged = run({ settings = { purged_devices = { "DeviceA" } } },
            { DeviceA = { removed = true, timestamp = "2026-01-01 00:00:00" } },
            {})
        assert.is_true(ok)
        assert.is_equal("2026-01-01 00:00:00", merged.DeviceA.timestamp)
    end)
end)
