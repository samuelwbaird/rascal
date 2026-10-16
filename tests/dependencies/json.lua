-- cjson and cmsgpack
local cjson = require('cjson')
local cjson_safe = require('cjson.safe')
local cmsgpack = require('cmsgpack')

local value = { name = 'rascal', list = { 1, 2, 3 }, nested = { ok = true } }

local decoded = cjson.decode(cjson.encode(value))
expect_equal(decoded.name, 'rascal')
expect_equal(decoded.list[3], 3)
expect_equal(decoded.nested.ok, true)
expect_equal(cjson.encode({ 1.5 }), '[1.5]')

local result, err = cjson_safe.decode('{ broken')
expect_equal(result, nil)
assert(err)

local unpacked = cmsgpack.unpack(cmsgpack.pack(value))
expect_equal(unpacked.name, 'rascal')
expect_equal(unpacked.list[2], 2)
expect_equal(unpacked.nested.ok, true)

local a, b, c = cmsgpack.unpack(cmsgpack.pack(1, 'two', 3.5))
expect_equal(a, 1)
expect_equal(b, 'two')
expect_equal(c, 3.5)
