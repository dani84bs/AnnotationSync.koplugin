describe("Progress sync excluded directories (Issue #80)", function()
    local utils

    setup(function()
        require("commonrequire")
        local plugin_path = "plugins/AnnotationSync.koplugin/?.lua"
        package.path = plugin_path .. ";" .. package.path

        utils = require("utils")
    end)

    it("excludes an exact directory match", function()
        assert.is_true(utils.is_path_excluded("/books/Comics", {"/books/Comics"}))
    end)

    it("excludes a subdirectory of an excluded directory", function()
        assert.is_true(utils.is_path_excluded("/books/Comics/Vol1", {"/books/Comics"}))
    end)

    it("does not exclude a sibling directory sharing a string prefix", function()
        assert.is_false(utils.is_path_excluded("/books/Comics2", {"/books/Comics"}))
    end)

    it("ignores trailing slashes in the stored setting", function()
        assert.is_true(utils.is_path_excluded("/books/Comics/Vol1", {"/books/Comics/"}))
    end)

    it("ignores trailing slashes in the directory being checked", function()
        assert.is_true(utils.is_path_excluded("/books/Comics/", {"/books/Comics"}))
    end)

    it("returns false for an empty exclude list", function()
        assert.is_false(utils.is_path_excluded("/books/Comics", {}))
    end)

    it("returns false when excluded_dirs is nil", function()
        assert.is_false(utils.is_path_excluded("/books/Comics", nil))
    end)

    it("matches against any of multiple excluded directories", function()
        local excluded = {"/books/Comics", "/books/Samples"}
        assert.is_true(utils.is_path_excluded("/books/Samples/foo", excluded))
        assert.is_false(utils.is_path_excluded("/books/Novels", excluded))
    end)

    it("supports the root directory as an excluded entry", function()
        assert.is_true(utils.is_path_excluded("/books/Comics", {"/"}))
    end)
end)
