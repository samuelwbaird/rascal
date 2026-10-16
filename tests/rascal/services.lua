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
expect_error('REP, PULL or PUB', services.serve, 'test_bad', 'ROUTER', { a = '' }, {})
expect_error('needs a target', services.serve, 'test_bad', 'REP', { a = '' })
expect_error('api description', services.serve, 'test_bad', 'REP', {}, {})
expect_error('cannot be used as a method name', services.serve, 'test_bad', 'REP', { close = '' }, {})
expect_error('EADDRINUSE', services.serve, 'test_store', 'REP', { a = '' }, {})

-- connect and subscribe check the kind of service
local publisher = services.serve('test_kind', 'PUB', { event = '' })
expect_error('use services.subscribe', services.connect, 'test_kind')
expect_error('use services.connect', services.subscribe, 'test_store', {})
publisher:close()

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
