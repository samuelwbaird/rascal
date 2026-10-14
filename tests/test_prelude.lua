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
