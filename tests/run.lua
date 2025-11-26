#!/usr/bin/env lua5.3

package.path = package.path .. ";./?.lua;./tests/?.lua"

package.preload['ui/elements/reader_menu_order'] = function()
    return require("mocks.reader_menu_order")
end
package.preload['ui/uimanager'] = function()
    return require("mocks.uimanager")
end
package.preload['ui/widget/infomessage'] = function()
    return require("mocks.infomessage")
end

luaunit = require("luaunit")

require("utils_test")

os.exit(luaunit.LuaUnit.run())
