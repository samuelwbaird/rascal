-- lua-zlib, with zlib
local zlib = require('zlib')

local text = string.rep('hello zlib ', 100)
for _, window in ipairs({ 15, 15 + 16, -15 }) do		-- zlib, gzip and raw deflate
	local compressed = zlib.deflate(6, window)(text, 'finish')
	assert(#compressed < #text, 'compressed with window ' .. window)
	expect_equal(zlib.inflate(window)(compressed), text, 'inflated with window ' .. window)
end

-- streams keep their state between calls
local deflate = zlib.deflate()
local parts = { deflate('hello '), (deflate('world', 'finish')) }
expect_equal(zlib.inflate()(table.concat(parts)), 'hello world')

expect_equal(zlib.crc32()('hello'), 0x3610a686)
assert(not pcall(zlib.inflate(), 'not compressed data'))
