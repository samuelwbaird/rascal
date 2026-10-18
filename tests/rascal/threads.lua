-- rascal.threads: starting threads with arguments, sharing the context
local threads = require('rascal.threads')
local messaging = require('rascal.messaging')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

-- arguments of any msgpack encodable type, results sent back over inproc
local results = messaging.bind('PULL', 'test_threads_results')
results:set_rcvtimeo(5000)
local worker = threads.start([[
	local text, number, flag, nothing, list = ...
	local cjson = require('cjson')
	local push = require('rascal.messaging').connect('PUSH', 'test_threads_results')
	push:send(cjson.encode({
		text = text,
		number = number,
		flag = flag,
		nothing = nothing == nil,
		list_total = list[1] + list[2] + list.nested.value,
		class = type(class),
	}))
	push:close()
]], 'words', 42, true, nil, { 10, 20, nested = { value = 12 } })
local received = require('cjson').decode((assert(results:recv())))
expect_equal(received.text, 'words')
expect_equal(received.number, 42)
expect_equal(received.flag, true)
expect_equal(received.nothing, true)
expect_equal(received.list_total, 42)
expect_equal(received.class, 'function', 'init has run in the thread')

worker:join()
expect_equal(worker:alive(), false)
results:close()

-- only values that can be passed between threads
expect_error('cannot pass a function', threads.start, 'return', print)
expect_error('cannot pass a userdata', threads.start, 'return', { io.stdout })
local loop = {}
loop.self = loop
expect_error('contains itself', threads.start, 'return', loop)
expect_error('must be a function or a string', threads.start, 42)

-- thread code can be a function, using its arguments, globals and require
local function_results = messaging.bind('PULL', 'test_threads_function')
function_results:set_rcvtimeo(5000)
threads.start(function (name, values)
	local push = require('rascal.messaging').connect('PUSH', 'test_threads_function')
	push:send(name .. ' ' .. values[1] + values[2] .. ' ' .. type(class))
	push:close()
end, 'function', { 20, 22 })
expect_equal(function_results:recv(), 'function 42 function')
function_results:close()

-- but not local variables from outside it
local outside = 'not passed'
expect_error("refers to 'outside' from outside it", threads.start, function () print(outside) end)
expect_error('unable to pass this function', threads.start, print)

-- errors in a function thread report its source file and line
local function_output = run_rascal_script([[
	require('rascal.threads').start(function ()
		error('function thread failure')
	end)
]])
assert(function_output:find('thread failed: [^\n]*:2: function thread failure'), function_output)

-- the main thread waits for its threads after the script, then exits
expect_equal(run_rascal_script([[
	local threads = require('rascal.threads')
	threads.start([==[
		require('rascal.messaging').loop():add_once(100, function () print('thread finished') end)
	]==])
	print('script finished')
]]), 'script finished\nthread finished')

-- threads wait for the threads they start
expect_equal(run_rascal_script([[
	require('rascal.threads').start([==[
		require('rascal.threads').start([=[
			require('rascal.messaging').loop():add_once(100, function () print('grandchild finished') end)
		]=])
		print('child finished')
	]==])
]]), 'child finished\ngrandchild finished')

-- a failing thread reports its error, and the rest of the process continues
local output = run_rascal_script([[
	local threads = require('rascal.threads')
	threads.start([==[
		local function broken() error('deliberate failure') end
		broken()
	]==])
	threads.start('this is not lua')
	threads.start([==[ require('rascal.messaging').loop():add_once(100, function () print('other thread finished') end) ]==])
]])
assert(output:find('thread failed: thread:1: deliberate failure\nstack traceback:', 1, true), output)
assert(output:find("in local 'broken'", 1, true), output)
assert(not output:find('rascal/threads.lua', 1, true), 'traceback leaves out the bootstrap: ' .. output)
assert(output:find('thread failed: thread:1: syntax error', 1, true), output)
assert(output:find('other thread finished', 1, true), output)

-- threads work without init, reporting failures with print
expect_equal(run_rascal_script([[
	require('rascal.threads').start([==[ print(type(class)) error('no init') ]==])
]], '--no-init'):match('^nil\nthread failed: thread:1: no init'), 'nil\nthread failed: thread:1: no init')
