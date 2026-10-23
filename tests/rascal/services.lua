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
wait_until(function () return store:get('pushed') == 10 end)
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
	-- the first ping received shows the subscription is connected
	function subscriber:ping()
		if not self.ready then
			self.ready = true
			forward:send('ready')
		end
	end
	function subscriber:moved(name, x, y)
		forward:send(name .. ' moved to ' .. x .. ',' .. y)
		if name == 'last' then
			subscription:close()
			forward:close()
		end
	end
	subscription = services.subscribe('test_events', subscriber)
]])
local events = services.serve('test_events', 'PUB', {
	ping = '',
	moved = 'name:string, x:number, y:number',
	ignored = 'anything:*',
})
-- published calls are dropped until the subscription connects, so ping until it is
assert(wait_until(function ()
	events:ping()
	return received:recv(messaging.zmq.DONTWAIT) == 'ready'
end), 'the subscriber received a ping')
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
	function slow:hold(milliseconds)
		local started = require('rascal.messaging').connect('PUSH', 'test_slow_started')
		started:send('holding')
		started:close()
		coroutine.yield(milliseconds)
		return 'held'
	end
	function slow:stop() slow_service:close() end
	slow_service = services.serve('test_slow', 'ROUTER', {
		hold = 'milliseconds:number -> label:string',
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
for _, wait in ipairs({ 400, 401, 402 }) do
	threads.start(caller, wait)
end
local labels = {}
for i = 1, 3 do
	labels[i] = done:recv()
end
local elapsed = messaging.utc_time() - started
assert(elapsed < 1.0, 'three 400ms calls took ' .. elapsed .. 's, so were not in progress at the same time')
table.sort(labels)
expect_equal(table.concat(labels, ', '), 'caller 400, caller 401, caller 402')

-- closing waits for the calls in progress to reply
local holding = messaging.bind('PULL', 'test_slow_started')
holding:set_rcvtimeo(5000)
threads.start(function ()
	local result = require('rascal.services').connect('test_slow'):hold(200)
	local push = require('rascal.messaging').connect('PUSH', 'test_slow_done')
	push:send(result)
	push:close()
end)
expect_equal(holding:recv(), 'holding', 'the call is in progress')
holding:close()
slow:stop()
expect_equal(done:recv(), 'held')
done:close()
wait_until(function () return services.find('test_slow') == nil end)
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
		local result = dealer:wait(400, name)
		finished[#finished + 1] = result
	end)
end
wait_until(function () return #finished == 3 end)
expect_equal(#finished, 3)
assert(messaging.utc_time() - dealer_started < 1.0, 'three 400ms calls on one DEALER connection were not in progress at the same time')
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
wait_until(function () return dealer_results.rep ~= nil end)
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

-- a balanced service spreads calls across worker threads, each answering the same api
local balanced = services.serve_balanced('test_balanced', 3, {
	square = 'n:number -> result:number, worker:number',
	wait = 'milliseconds:number -> worker:number',
	fail = '',
}, function (number, offset)
	local worker = {}
	function worker:square(n) return n * n + offset, number end
	function worker:wait(milliseconds)
		coroutine.yield(milliseconds)
		return number
	end
	function worker:fail() error('worker ' .. number .. ' failed') end
	return worker
end, 1)
expect_equal(services.find('test_balanced').socket_type, 'REQ', 'callers use REQ as for REP')

-- called from another thread, as calls from this thread would wait on this thread's own loop
local balanced_results = messaging.bind('PULL', 'test_balanced_results')
threads.start(function ()
	local cjson = require('cjson')
	local services = require('rascal.services')
	local push = require('rascal.messaging').connect('PUSH', 'test_balanced_results')
	local square = services.connect('test_balanced')

	-- one call at a time, so workers take turns
	local by_worker = {}
	local value
	for i = 1, 30 do
		local result, worker = square:square(i)
		value = result
		by_worker[worker] = (by_worker[worker] or 0) + 1
	end
	local ok, err = pcall(square.fail, square)

	-- several calls at once on a DEALER connection, each worker yielding
	local dealer = services.connect('test_balanced', 'DEALER')
	local waits = {}
	local started = require('rascal.messaging').utc_time()
	for i = 1, 3 do
		loop:schedule(function ()
			local worker = dealer:wait(400)
			waits[#waits + 1] = worker
			if #waits == 3 then
				push:send(cjson.encode({
					value = value,
					by_worker = by_worker,
					error = err,
					elapsed = require('rascal.messaging').utc_time() - started,
				}))
				push:close()
			end
		end)
	end
end)
-- the balancer runs on this thread's loop, so wait by running the loop
local report_message = nil
wait_until(function ()
	report_message = balanced_results:recv(messaging.zmq.DONTWAIT)
	return report_message ~= nil
end)
local balanced_report = require('cjson').decode((assert(report_message, 'no report from the balanced service caller')))
balanced_results:close()
expect_equal(balanced_report.value, 30 * 30 + 1, 'worker arguments are passed on')
expect_equal(table.concat(balanced_report.by_worker, ','), '10,10,10')
assert(balanced_report.error:find('test_balanced:fail failed: [^\n]*worker %d failed'), balanced_report.error)
assert(balanced_report.elapsed < 1.0, 'three 400ms calls were not in progress at the same time: ' .. balanced_report.elapsed)

-- closing stops the service and its workers
balanced:close()
expect_equal(services.find('test_balanced'), nil)
expect_error('at least one worker', services.serve_balanced, 'test_bad', 0, { a = '' }, function () end)
local captured = {}
expect_error("refers to 'captured'", services.serve_balanced, 'test_bad', 1, { a = '' }, function () return captured end)

-- a worker that fails to start is left out, the others answer every call
local partial = run_rascal_script([[
	local services = require('rascal.services')
	local service = services.serve_balanced('partial', 2, { number = '-> number:number' }, function (number)
		if number == 1 then
			error('worker 1 could not start')
		end
		return { number = function () return number end }
	end)
	require('rascal.threads').start(function ()
		local partial = require('rascal.services').connect('partial')
		local numbers = {}
		for i = 1, 4 do
			numbers[#numbers + 1] = partial:number()
		end
		print('answered by ' .. table.concat(numbers, ','))
	end)
	loop:add_once(500, function () service:close() end)
]])
assert(partial:find('thread failed: [^\n]*worker 1 could not start'), partial)
assert(partial:find('answered by 2,2,2,2', 1, true), partial)

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
