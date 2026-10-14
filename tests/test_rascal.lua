-- the rascal module describes the build
local rascal = require('rascal')

expect_equal(type(rascal.version), 'string')
expect_equal(rascal.lua_version:match('^Lua 5%.%d'), _VERSION)
expect_equal(type(rascal.dependencies.lua), 'string')
expect_equal(rascal.lua_version, 'Lua ' .. rascal.dependencies.lua)

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then return true end
	end
	return false
end

-- every listed module can be required
for _, name in ipairs(rascal.c_modules) do
	assert(package.preload[name], 'c module not preloaded: ' .. name)
	require(name)
end
for _, name in ipairs(rascal.lua_modules) do
	require(name)
end
assert(contains(rascal.c_modules, 'lfs'))
assert(contains(rascal.lua_modules, 'prelude'))

-- embedded sources are available for inspection
local source, path = rascal.source('prelude')
expect_equal(path, 'lua/prelude.lua')
assert(source:find('return prelude', 1, true))
expect_equal(rascal.source('no.such.module'), nil)

-- missing modules report the embedded searcher in the error
local ok, err = pcall(require, 'no.such.module')
assert(not ok and err:find("no embedded module 'no.such.module'", 1, true), err)

-- module search paths come from RASCAL_PATH / RASCAL_CPATH, never LUA_PATH
assert(not package.path:find('/usr/local/', 1, true), package.path)
if not os.getenv('RASCAL_PATH') then
	expect_equal(package.path, './?.lua;./?/init.lua')
end
