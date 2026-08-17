-- E2E: two-device settings sync over a real local WebDAV server.
--
-- Simulates two genuinely separate devices as two genuinely separate OS
-- processes (see docs/adr/0004-e2e-multi-device-sequential.md): device A
-- boots, pushes a setting, and exits cleanly; device B then boots fresh
-- and pulls, correctly seeing device A's setting -- exercising the
-- device_id-keyed merge in settings_sync.lua that a single-device round
-- trip can't touch at all.
describe("AnnotationSync E2E two-device settings sync", function()
    local two_device_harness

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        two_device_harness = require("spec/e2e/two_device_harness")
    end)

    it("device B sees device A's setting after A pushes and exits", function()
        local ok_a, output_a = two_device_harness.run_device("settings_sync_two_device_driver_a")
        assert.is_true(ok_a, "device A process failed:\n" .. tostring(output_a))

        local ok_b, output_b = two_device_harness.run_device("settings_sync_two_device_driver_b")
        assert.is_true(ok_b, "device B process failed:\n" .. tostring(output_b))
    end)
end)
