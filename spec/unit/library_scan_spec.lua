describe("Library scan for unsynced books (gh-89)", function()
    local docsettings, library_scan
    local test_data_dir = os.getenv("PWD") .. "/test_library_scan_tmp"
    local fixture_epub = os.getenv("PWD") .. "/test/juliet.epub"

    local function make_book(relative_path)
        local dest = test_data_dir .. "/" .. relative_path
        local dir = dest:match("(.*)/")
        if dir then os.execute("mkdir -p " .. dir) end
        os.execute("cp " .. fixture_epub .. " " .. dest)
        return dest
    end

    local function give_annotations(file, annotations)
        local sidecar = docsettings:open(file)
        sidecar:saveSetting("annotations", annotations)
        sidecar:flush()
    end

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        docsettings = require("frontend/docsettings")
        library_scan = require("library_scan")
    end)

    before_each(function()
        os.execute("rm -rf " .. test_data_dir)
        os.execute("mkdir -p " .. test_data_dir)
    end)

    teardown(function()
        os.execute("rm -rf " .. test_data_dir)
        package.loaded["library_scan"] = nil
    end)

    it("finds a book with local annotations", function()
        local file = make_book("annotated.epub")
        give_annotations(file, {{ page = 1, text = "hi" }})

        local found = library_scan.find_unsynced_books(test_data_dir, {})

        assert.is_equal(1, #found)
        assert.is_equal(file, found[1])
    end)

    it("skips a book with no annotations", function()
        make_book("empty.epub")

        local found = library_scan.find_unsynced_books(test_data_dir, {})

        assert.is_equal(0, #found)
    end)

    it("skips a book that has never been opened (no sidecar at all)", function()
        make_book("never_opened.epub")

        local found, scanned = library_scan.find_unsynced_books(test_data_dir, {})

        assert.is_equal(0, #found)
        assert.is_equal(1, scanned)
    end)

    it("recurses into subdirectories", function()
        local file = make_book("sub/dir/nested.epub")
        give_annotations(file, {{ page = 1, text = "hi" }})

        local found = library_scan.find_unsynced_books(test_data_dir, {})

        assert.is_equal(1, #found)
        assert.is_equal(file, found[1])
    end)

    it("skips directories excluded from sync", function()
        local excluded_dir = test_data_dir .. "/excluded"
        local file = make_book("excluded/book.epub")
        give_annotations(file, {{ page = 1, text = "hi" }})

        local found = library_scan.find_unsynced_books(test_data_dir, { excluded_dir })

        assert.is_equal(0, #found)
    end)

    it("counts scanned books and reports skipped books whose sidecar can't be read", function()
        local good = make_book("good.epub")
        give_annotations(good, {{ page = 1, text = "hi" }})
        local bad = make_book("bad.epub")
        give_annotations(bad, {{ page = 1, text = "hi" }})

        local old_open = docsettings.open
        docsettings.open = function(this, file)
            if file == bad then
                error("simulated corrupt sidecar")
            end
            return old_open(this, file)
        end

        local found, scanned, skipped = library_scan.find_unsynced_books(test_data_dir, {})

        docsettings.open = old_open

        assert.is_equal(1, #found)
        assert.is_equal(good, found[1])
        assert.is_equal(2, scanned)
        assert.is_equal(1, skipped)
    end)

    it("ignores non-document files", function()
        os.execute("mkdir -p " .. test_data_dir)
        local f = io.open(test_data_dir .. "/notes.dat", "w")
        f:write("not a book")
        f:close()

        local found, scanned = library_scan.find_unsynced_books(test_data_dir, {})

        assert.is_equal(0, #found)
        assert.is_equal(0, scanned)
    end)
end)
