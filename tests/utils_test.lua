json = require("tests/mocks/json")
_ = require("tests/mocks/gettext")

-- These are required by utils.lua. We require them here with the same path
-- so we get the same (mocked) module instance.
reader_order = require("ui/elements/reader_menu_order")
UIManager = require("ui/uimanager")
InfoMessage = require("ui/widget/infomessage")


local utils = require("utils")

TestUtils = {}

function TestUtils:setUp()
    -- Reset mock state before each test
    reader_order.tools = { "statistics" }
end

function TestUtils:testReadJsonValid()
    local f = io.open("test.json", "w")
    f:write('{"key": "value"}')
    f:close()
    local data = utils.read_json("test.json")
    luaunit.assertEquals(data.key, "value")
    os.remove("test.json")
end

function TestUtils:testReadJsonEmptyFile()
    local f = io.open("test.json", "w")
    f:write("")
    f:close()
    local data = utils.read_json("test.json")
    luaunit.assertEquals(data, {})
    os.remove("test.json")
end

function TestUtils:testReadJsonNonExistentFile()
    local data = utils.read_json("non_existent_file.json")
    luaunit.assertEquals(data, {})
end

function TestUtils:testReadJsonInvalidJson()
    local f = io.open("test.json", "w")
    f:write("invalid json")
    f:close()
    local data = utils.read_json("test.json")
    luaunit.assertEquals(data, {})
    os.remove("test.json")
end

function TestUtils:testInsertAfterStatistics()
    utils.insert_after_statistics("test_key")
    luaunit.assertEquals(reader_order.tools[2], "test_key")
end
