local DocumentRegistry = require("document/documentregistry")
local docsettings = require("frontend/docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local utils = require("utils")

local M = {}

function M.book_has_annotations(file)
    local sidecar = docsettings:open(file)
    local annotations = sidecar:readSetting("annotations")
    return type(annotations) == "table" and #annotations > 0
end

-- Recursively finds books under root_dir that already carry local
-- annotations, for a "sync everything, not just what's dirty" pass. Books
-- with no annotations are skipped since there's nothing to upload, and a
-- book whose sidecar can't be read is counted as skipped rather than
-- aborting the whole scan.
function M.find_unsynced_books(root_dir, excluded_dirs)
    local found, scanned, skipped = {}, 0, 0
    local scan_dirs = { root_dir }

    while #scan_dirs > 0 do
        local next_dirs = {}
        for _, dir in ipairs(scan_dirs) do
            if not utils.is_path_excluded(dir, excluded_dirs) then
                local ok, iter, dir_obj = pcall(lfs.dir, dir)
                if ok then
                    for entry in iter, dir_obj do
                        if entry ~= "." and entry ~= ".." then
                            local fullpath = dir == "/" and ("/" .. entry) or (dir .. "/" .. entry)
                            local attributes = lfs.attributes(fullpath)
                            if attributes and attributes.mode == "directory" then
                                if not entry:match("%.sdr$") then
                                    table.insert(next_dirs, fullpath)
                                end
                            elseif attributes and attributes.mode == "file" and DocumentRegistry:hasProvider(fullpath) then
                                scanned = scanned + 1
                                local read_ok, has_annotations = pcall(M.book_has_annotations, fullpath)
                                if not read_ok then
                                    skipped = skipped + 1
                                    logger.warn("AnnotationSync: could not read sidecar for " .. fullpath)
                                elseif has_annotations then
                                    table.insert(found, fullpath)
                                end
                            end
                        end
                    end
                end
            end
        end
        scan_dirs = next_dirs
    end

    return found, scanned, skipped
end

return M
