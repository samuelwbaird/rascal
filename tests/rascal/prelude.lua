-- the embedded prelude library
local prelude = require('prelude')

local Point = prelude.class()
function Point:init(x, y)
	self.x, self.y = x, y
end
function Point:length()
	return math.sqrt(self.x * self.x + self.y * self.y)
end
expect_equal(Point(3, 4):length(), 5.0)

local l = prelude.list({ 1, 2, 3 })
expect_equal(#l, 3)

local copy = prelude.deserialise(prelude.serialise({ a = 1, b = { 'x' } }))
expect_equal(copy.a, 1)
expect_equal(copy.b[1], 'x')

local ro = prelude.readonly({ a = 1 })
expect_equal(ro.a, 1)
assert(not pcall(function () ro.b = 2 end), 'readonly table should reject writes')

-- list.wrap and list.pack produce lists
local wrapped = prelude.list.wrap({ 'a', 'b' })
expect_equal(getmetatable(wrapped), prelude.list)
expect_equal(wrapped:pop(), 'b')
local packed = prelude.list.pack(1, 2, 3)
expect_equal(getmetatable(packed), prelude.list)
expect_equal(#packed, 3)

-- random returns an item and its index, or nil when empty
local picks = prelude.list({ 'a', 'b', 'c' })
local item, index = picks:random()
expect_equal(picks[index], item)
picks:remove(index)
expect_equal(#picks, 2)
expect_equal(prelude.list():random(), nil)

-- pcall_trace passes its arguments, and adds a stack trace to errors
local ok, sum = prelude.pcall_trace(function (a, b) return a + b end, 2, 3)
expect_equal(ok, true)
expect_equal(sum, 5)
local ok, err = prelude.pcall_trace(function (message) error(message) end, 'traced')
expect_equal(ok, false)
assert(err:find('traced', 1, true) and err:find('stack traceback', 1, true), 'error should include a stack trace')

-- serialising keeps its helper out of the globals
expect_equal(rawget(_G, 'encode_value'), nil)

-- proxy_chain reads each key from the first object that has it, and methods
-- called through the proxy receive the object that has them as self
local base = { name = 'base', shared = 'from base' }
function base:is_base() return self == base end
local top = { shared = 'from top', enabled = false }
local proxy = prelude.proxy_chain(top, base)
expect_equal(proxy.shared, 'from top')
expect_equal(proxy.name, 'base')
expect_equal(proxy.enabled, false)
expect_equal(proxy:is_base(), true)
expect_equal(proxy.missing, nil)

-- proxy_chain works without the init globals
local output, success = run_rascal_script([[
	local proxy = require('prelude').proxy_chain({ a = 1 }, { b = 2 })
	print(proxy.a + proxy.b)
]], '--no-init')
expect_equal(output, '3')
assert(success, 'proxy_chain should work under --no-init')
