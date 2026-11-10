-- luautf8, require 'lua-utf8', beside Lua's own utf8 library
local utf8x = require('lua-utf8')

expect_equal(utf8x.len('héllo'), 5)
expect_equal(utf8x.upper('héllo'), 'HÉLLO')
expect_equal(utf8x.lower('ÀÉÎ'), 'àéî')
expect_equal(utf8x.sub('日本語テキスト', 2, 3), '本語')
expect_equal(utf8x.reverse('añb'), 'bña')
expect_equal(utf8x.width('日本'), 4, 'wide characters are two columns')
expect_equal(utf8x.match('café 42', '(%a+)'), 'café', 'patterns match by character')

-- Lua's own utf8 library is unchanged
expect_equal(utf8.char(72, 228), 'Hä')
expect_equal(utf8.len('héllo'), 5)
assert(utf8 ~= utf8x)
