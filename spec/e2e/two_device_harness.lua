-- Two-device process harness: launches a device-driver e2e spec as a
-- genuinely separate OS process (a fresh `kodev test front <name>` run,
-- KO_HOME-isolated the same way koreader's own meson test runner isolates
-- concurrent busted processes -- see docs/adr/0004), waits for it to exit,
-- then returns. Callers run device A to completion before starting device
-- B: sequential, not concurrent (per ADR 0004).
local M = {}

local function shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Runs `driver_spec_name` (a spec/e2e/<driver_spec_name>_spec.lua already
-- symlinked into the koreader checkout by run_e2e_tests.sh) as its own
-- `kodev test front` process. Returns true plus captured output on a clean
-- exit, false plus captured output otherwise.
function M.run_device(driver_spec_name)
    local ko_dir = os.getenv("ANNOTATIONSYNC_E2E_KO_DIR")
    assert(ko_dir, "ANNOTATIONSYNC_E2E_KO_DIR is not set -- run via run_e2e_tests.sh")

    -- `kodev test` isolates each device's KO_HOME by test name only when it
    -- runs via the meson test runner; its --busted fallback (used silently
    -- when meson isn't installed) shares one KO_HOME across every test,
    -- which would collapse device isolation without failing loudly.
    assert(
        os.execute("command -v meson >/dev/null 2>&1") == 0,
        "meson is required for per-device KO_HOME isolation -- see kodev test's --meson/--busted fallback"
    )

    local cmd = string.format(
        "cd %s && ./kodev test front %s 2>&1",
        shell_quote(ko_dir), shell_quote(driver_spec_name)
    )
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    local ok = handle:close()
    return ok == true, output
end

return M
