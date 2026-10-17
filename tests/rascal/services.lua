-- rascal.services: serving and connecting by name, over REQ/REP, PUSH/PULL and PUB/SUB
local services = require('rascal.services')
local threads = require('rascal.threads')
local messaging = require('rascal.messaging')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

-- a service served from another thread, which is started after the client
-- begins waiting for it
threads.start([[
	require('rascal.messaging').loop():add_once(50, function ()
		local services = require('rascal.services')
		local store = { values = {} }
		function store:set(key, value) self.values[key] = value end
		function store:get(key) return self.values[key] end
		function store:echo(...) return ... end
		function store:fail(message) error(message) end
		function store:unsendable() return print end
		local api = {
			set = 'key:string, value:*',
			get = 'key:string -> value:*',
			echo = '... -> ...',
			fail = 'message:string',
			unsendable = '-> function',
		}
		services.serve('test_store', 'REP', api, store)
		services.serve('test_store_push', 'PULL', { set = api.set }, store)
	end)
]])

-- request and reply, values by position
local store = services.connect('test_store')
store:set('answer', 42)
expect_equal(store:get('answer'), 42)
local a, b, c, d = store:echo('one', nil, { list = { 1, 2 } }, true)
expect_equal(a, 'one')
expect_equal(b, nil)
expect_equal(c.list[2], 2)
expect_equal(d, true)
expect_equal(select('#', store:echo(1, 2, 3)), 3)

-- errors are returned to the caller, with the service's stack trace
expect_error('services: test_store:fail failed: thread:%d+: deliberate', store.fail, store, 'deliberate')
expect_error('unable to return the result', store.unsendable, store)
expect_error('cannot pass a function', store.set, store, 'bad', print)
-- the connection is still usable after errors
expect_equal(store:get('answer'), 42)

-- push, calls return straight away and are handled in order
local push_store = services.connect('test_store_push')
for i = 1, 10 do
	push_store:set('pushed', i)
end
local waited = 0
while store:get('pushed') ~= 10 and waited < 100 do
	messaging.loop():sleep_ex(10)
	waited = waited + 1
end
expect_equal(store:get('pushed'), 10)

-- the registry
local details = services.find('test_store')
expect_equal(details.socket_type, 'REQ')
expect_equal(details.endpoint, 'inproc://test_store')
expect_equal(details.api.get, 'key:string -> value:*')
expect_equal(services.find('test_no_such_service'), nil)

-- publish and subscribe: a subscriber thread forwards what it receives
local received = messaging.bind('PULL', 'test_services_received')
received:set_rcvtimeo(5000)
threads.start([[
	local services = require('rascal.services')
	local messaging = require('rascal.messaging')
	local forward = messaging.connect('PUSH', 'test_services_received')
	-- only some of the published methods are handled
	local subscriber = {}
	function subscriber:moved(name, x, y)
		forward:send(name .. ' moved to ' .. x .. ',' .. y)
		if name == 'last' then
			subscription:close()
			forward:close()
		end
	end
	subscription = services.subscribe('test_events', subscriber)
	forward:send('subscribed')
]])
local events = services.serve('test_events', 'PUB', {
	moved = 'name:string, x:number, y:number',
	ignored = 'anything:*',
})
expect_equal(received:recv(), 'subscribed')
-- give the subscription time to connect, published calls before then are dropped
messaging.loop():sleep_ex(100)
events:ignored('not handled')
events:moved('cat', 1, 2)
events:moved('last', 3, 4)
expect_equal(received:recv(), 'cat moved to 1,2')
expect_equal(received:recv(), 'last moved to 3,4')
received:close()

-- closing a service removes it from the registry
events:close()
expect_equal(services.find('test_events'), nil)

-- a service can also be bound to a network endpoint
local network = services.serve('test_network', 'PULL', { note = 'text:string' }, { note = function () end })
local endpoint = network:bind_network('tcp://127.0.0.1:*')
assert(endpoint:match('^tcp://127%.0%.0%.1:%d+$'), endpoint)
network:close()

-- mistakes are reported
expect_error('REP, ROUTER, PULL or PUB', services.serve, 'test_bad', 'DEALER', { a = '' }, {})
expect_error('needs a target', services.serve, 'test_bad', 'REP', { a = '' })
expect_error('api description', services.serve, 'test_bad', 'REP', {}, {})
expect_error('cannot be used as a method name', services.serve, 'test_bad', 'REP', { close = '' }, {})
expect_error('EADDRINUSE', services.serve, 'test_store', 'REP', { a = '' }, {})

-- connect and subscribe check the kind of service
local publisher = services.serve('test_kind', 'PUB', { event = '' })
expect_error('use services.subscribe', services.connect, 'test_kind')
expect_error('use services.connect', services.subscribe, 'test_store', {})
publisher:close()

-- ROUTER services run each call as a coroutine, so a method can yield
threads.start([[
	local services = require('rascal.services')
	local slow = {}
	function slow:wait(milliseconds, label)
		coroutine.yield(milliseconds)
		return label, milliseconds
	end
	function slow:quick() return 'quick' end
	function slow:fail()
		coroutine.yield(10)
		error('failed after yielding')
	end
	function slow:stop() slow_service:close() end
	slow_service = services.serve('test_slow', 'ROUTER', {
		wait = 'milliseconds:number, label:string -> label:string, milliseconds:number',
		quick = '-> result:string',
		fail = '',
		stop = '',
	}, slow)
]])
local slow = services.connect('test_slow')
expect_equal(services.find('test_slow').socket_type, 'REQ', 'callers use REQ as for REP')
expect_equal(slow:quick(), 'quick')
local label, milliseconds = slow:wait(10, 'waited')
expect_equal(label, 'waited')
expect_equal(milliseconds, 10)
expect_error('services: test_slow:fail failed: thread:%d+: failed after yielding', slow.fail, slow)

-- calls from several callers are in progress at the same time
local done = messaging.bind('PULL', 'test_slow_done')
done:set_rcvtimeo(5000)
local caller = [[
	local wait = ...
	local result = require('rascal.services').connect('test_slow'):wait(wait, 'caller ' .. wait)
	local push = require('rascal.messaging').connect('PUSH', 'test_slow_done')
	push:send(result)
	push:close()
]]
local started = messaging.utc_time()
for _, wait in ipairs({ 300, 301, 302 }) do
	threads.start(caller, wait)
end
local labels = {}
for i = 1, 3 do
	labels[i] = done:recv()
end
local elapsed = messaging.utc_time() - started
assert(elapsed < 0.8, 'three 300ms calls took ' .. elapsed .. 's, so were not in progress at the same time')
table.sort(labels)
expect_equal(table.concat(labels, ', '), 'caller 300, caller 301, caller 302')

-- closing waits for the calls in progress to reply
threads.start(caller, 200)
loop:sleep_ex(100)
slow:stop()
expect_equal(done:recv(), 'caller 200')
done:close()
local checks = 0
while services.find('test_slow') and checks < 50 do
	loop:sleep_ex(10)
	checks = checks + 1
end
expect_equal(services.find('test_slow'), nil, 'closed once the call in progress replied')

-- DEALER connections park only the calling coroutine until the reply arrives
threads.start([[
	local services = require('rascal.services')
	local async = {}
	function async:wait(milliseconds, label)
		coroutine.yield(milliseconds)
		return label
	end
	function async:fail() error('failed for the dealer') end
	services.serve('test_async', 'ROUTER', {
		wait = 'milliseconds:number, label:string -> label:string',
		fail = '',
	}, async)
]])
local dealer = services.connect('test_async', 'DEALER')
expect_error('must be made from within a coroutine', dealer.wait, dealer, 1, 'outside')

-- several coroutines in this one thread, each with a call in progress at the same time
local finished = {}
local dealer_started = messaging.utc_time()
for _, name in ipairs({ 'first', 'second', 'third' }) do
	loop:schedule(function ()
		local result = dealer:wait(200, name)
		finished[#finished + 1] = result
	end)
end
while #finished < 3 and messaging.utc_time() - dealer_started < 5 do
	loop:sleep_ex(10)
end
expect_equal(#finished, 3)
assert(messaging.utc_time() - dealer_started < 0.5, 'calls on one DEALER connection were not in progress at the same time')
table.sort(finished)
expect_equal(table.concat(finished, ', '), 'first, second, third')

-- errors are raised in the calling coroutine, and DEALER also works with REP services
local dealer_results = {}
loop:schedule(function ()
	dealer_results.error = select(2, pcall(dealer.fail, dealer))
	local rep_dealer = services.connect('test_store', 'DEALER')
	dealer_results.rep = rep_dealer:get('answer')
	rep_dealer:close()
end)
while dealer_results.rep == nil and messaging.utc_time() - dealer_started < 5 do
	loop:sleep_ex(10)
end
assert(tostring(dealer_results.error):find('failed for the dealer', 1, true), tostring(dealer_results.error))
expect_equal(dealer_results.rep, 42)

-- closing the connection resumes waiting calls with an error
local closed_error = nil
loop:schedule(function ()
	closed_error = select(2, pcall(dealer.wait, dealer, 1000, 'never'))
end)
dealer:close()
assert(tostring(closed_error):find('was closed while waiting for wait', 1, true), tostring(closed_error))
expect_error('connect with REQ or DEALER', services.connect, 'test_async', 'ROUTER')

-- an idle DEALER connection does not keep its thread running
expect_equal(run_rascal_script([[
	local services = require('rascal.services')
	require('rascal.threads').start([==[
		local echo = {}
		function echo:echo(text)
			echo_service:close()
			return text
		end
		echo_service = require('rascal.services').serve('echo', 'ROUTER', { echo = 'text:string -> text:string' }, echo)
	]==])
	local echo = services.connect('echo', 'DEALER')
	loop:schedule(function ()
		print(echo:echo('echoed'))
	end)
]]), 'echoed')

-- a process ends once its services are closed and its threads are complete
expect_equal(run_rascal_script([[
	local services = require('rascal.services')
	local threads = require('rascal.threads')
	local control = {}
	function control:stop()
		print('stopping')
		service:close()
	end
	service = services.serve('control', 'REP', { stop = '' }, control)
	threads.start("require('rascal.services').connect('control'):stop()")
	print('serving')
]]), 'serving\nstopping')
