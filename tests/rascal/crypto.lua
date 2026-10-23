-- rascal.crypto: digests, HMAC, encodings and secure random values
local crypto = require('rascal.crypto')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

-- digests, from the standard test vectors
expect_equal(crypto.hex(crypto.md5('')), 'd41d8cd98f00b204e9800998ecf8427e')
expect_equal(crypto.hex(crypto.sha1('abc')), 'a9993e364706816aba3e25717850c26c9cd0d89d')
expect_equal(crypto.hex(crypto.sha224('abc')), '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7')
expect_equal(crypto.hex(crypto.sha256('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
expect_equal(crypto.hex(crypto.sha384('abc')), 'cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7')
expect_equal(crypto.hex(crypto.sha512('abc')), 'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f')
expect_equal(crypto.digest('sha256', 'abc'), crypto.sha256('abc'))
expect_equal(#crypto.sha256(string.rep('x', 100000)), 32)
expect_error('bad argument', crypto.digest, 'sha3', 'abc')

-- hmac
expect_equal(crypto.hex(crypto.hmac('sha256', 'key', 'The quick brown fox jumps over the lazy dog')), 'f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8')
expect_equal(crypto.hex(crypto.hmac('sha1', 'key', 'The quick brown fox jumps over the lazy dog')), 'de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9')

-- hex
expect_equal(crypto.hex('\0\1\255'), '0001ff')
expect_equal(crypto.from_hex('0001FF'), '\0\1\255')
expect_equal(crypto.from_hex(''), '')
expect_equal(crypto.from_hex('abc'), nil, 'odd length')
expect_equal(crypto.from_hex('zz'), nil, 'not hexadecimal')

-- base64
expect_equal(crypto.base64(''), '')
expect_equal(crypto.base64('hello'), 'aGVsbG8=')
expect_equal(crypto.base64('\0\1\2\253\254\255'), 'AAEC/f7/')
expect_equal(crypto.from_base64('aGVsbG8='), 'hello')
expect_equal(crypto.from_base64('AAEC/f7/'), '\0\1\2\253\254\255')
expect_equal(crypto.from_base64('!!!!'), nil, 'not base64')
local bytes = crypto.random_bytes(1000)
expect_equal(crypto.from_base64(crypto.base64(bytes)), bytes)
expect_equal(crypto.from_hex(crypto.hex(bytes)), bytes)

-- random bytes
expect_equal(crypto.random_bytes(0), '')
expect_equal(#bytes, 1000)
assert(crypto.random_bytes(16) ~= crypto.random_bytes(16), 'random bytes should differ')

-- random integers, in range and each value seen
local seen = {}
for i = 1, 1000 do
	local value = crypto.random_int(1, 6)
	assert(value >= 1 and value <= 6, 'random_int out of range')
	seen[value] = true
end
for value = 1, 6 do
	assert(seen[value], 'random_int never chose ' .. value)
end
expect_equal(crypto.random_int(5, 5), 5)
expect_equal(math.type(crypto.random_int(-10, 10)), 'integer')
expect_error('min <= max', crypto.random_int, 6, 1)
expect_error('min <= max', crypto.random_int, 1, 6.5)
expect_error('too large', crypto.random_int, math.mininteger, math.maxinteger)

-- random tokens
local token = crypto.random_token(64)
expect_equal(#token, 64)
assert(not token:find('[^%w]'), 'default tokens are letters and digits')
assert(crypto.random_token(32) ~= crypto.random_token(32), 'tokens should differ')
expect_equal(crypto.random_token(0), '')
local code = crypto.random_token(2000, 'ab1')
assert(not code:find('[^ab1]'), 'tokens use only the given characters')
assert(code:find('a') and code:find('b') and code:find('1'), 'every character is used')
expect_equal(crypto.random_token(10, 'x'), 'xxxxxxxxxx')
expect_error('from 1 to 256', crypto.random_token, 8, '')

-- uuids
local uuid = crypto.uuid()
assert(uuid:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'), 'not a version 4 uuid: ' .. uuid)
assert(crypto.uuid() ~= uuid, 'uuids should differ')
