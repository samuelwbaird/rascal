-- llthreads2: each thread is a new Lua state, which must have the same
-- compiled in C modules and embedded Lua modules as the main state
local llthreads = require('llthreads2')

local thread = llthreads.new([[
	local cjson = require('cjson')
	local prelude = require('prelude')
	local sqlite3 = require('lsqlite3')
	local list = prelude.list({ ... })
	return cjson.encode({ count = #list, sqlite = sqlite3.version() })
]], 'a', 'b', 'c')

assert(thread:start())
local ok, result = thread:join()
assert(ok, result)
local decoded = require('cjson').decode(result)
expect_equal(decoded.count, 3)
expect_equal(decoded.sqlite, require('rascal.build').dependencies.sqlite)

-- several threads at once
local threads = {}
for i = 1, 4 do
	threads[i] = llthreads.new([[
		local n = ...
		local sum = 0
		for i = 1, 100000 do sum = sum + i % n end
		return n, sum
	]], i + 1)
	assert(threads[i]:start())
end
for i = 1, 4 do
	local ok, n = threads[i]:join()
	assert(ok)
	expect_equal(n, i + 1)
end
