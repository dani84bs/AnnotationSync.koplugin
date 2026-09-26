-- E2E: two-device reading-progress sync over a real local WebDAV server.
--
-- Simulates two genuinely separate devices as two genuinely separate OS
-- processes: device A
-- boots, reaches page 5, pushes progress, and exits cleanly; device B
-- then boots fresh and pulls, correctly seeing device A's page,
-- percentage, and device label in the "Jump to device progress" menu.
describe("AnnotationSync E2E two-device progress sync", function()
    local two_device_harness

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path
        two_device_harness = require("spec/e2e/two_device_harness")
    end)

    it("device B sees device A's progress after A pushes and exits", function()
        local ok_a, output_a = two_device_harness.run_device("progress_sync_two_device_driver_a")
        assert.is_true(ok_a, "device A process failed:\n" .. tostring(output_a))

        local ok_b, output_b = two_device_harness.run_device("progress_sync_two_device_driver_b")
        assert.is_true(ok_b, "device B process failed:\n" .. tostring(output_b))
    end)
end)
