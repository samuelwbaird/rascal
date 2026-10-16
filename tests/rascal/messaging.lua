-- rascal.messaging: context, sockets, loop and running to completion
local messaging = require('rascal.messaging')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

expect_equal(messaging.context(), messaging.context(), 'one context')
expect_equal(messaging.loop(), messaging.loop(), 'one loop per thread')
assert(math.abs(messaging.utc_time() - os.time()) < 2)

-- inproc by name, socket types by name or constant
local server = messaging.bind('PAIR', 'test_messaging')
local client = messaging.connect(messaging.zmq.PAIR, 'test_messaging')
client:send('hello')
expect_equal(server:recv(), 'hello')
server:close()
client:close()
expect_error('unknown socket type', messaging.socket, 'NOT_A_TYPE')
expect_error('unable to bind', messaging.bind_network, 'PAIR', 'not an endpoint')

-- network endpoints are explicit
local rep = messaging.bind_network('REP', 'tcp://127.0.0.1:*')
local req = messaging.connect_network('REQ', rep:get_last_endpoint())
req:send('ping')
expect_equal(rep:recv(), 'ping')
rep:send('pong')
expect_equal(req:recv(), 'pong')
rep:close()
req:close()

-- the loop runs sockets and timers
local pull = messaging.bind('PULL', 'test_messaging_loop')
local push = messaging.connect('PUSH', 'test_messaging_loop')
local received, fired = nil, false
messaging.loop():add_socket(pull, function (socket) received = socket:recv() end)
messaging.loop():add_once(10, function () fired = true end)
push:send('via loop')
messaging.loop():sleep_ex(100)
expect_equal(received, 'via loop')
expect_equal(fired, true)
messaging.loop():remove_socket(pull)
pull:close()
push:close()

-- after the script, the loop runs until it has no sockets or timers
expect_equal(run_rascal_script([[
	local messaging = require('rascal.messaging')
	local count, timer = 0, nil
	timer = messaging.loop():add_interval(20, function ()
		count = count + 1
		print('tick ' .. count)
		if count == 3 then
			timer:reset()
		end
	end)
	print('script done')
]]), 'script done\ntick 1\ntick 2\ntick 3')

-- a socket keeps the loop running until it is removed
expect_equal(run_rascal_script([[
	local messaging = require('rascal.messaging')
	local pull = messaging.bind('PULL', 'work')
	messaging.loop():add_socket(pull, function (socket)
		print((socket:recv()))
		messaging.loop():remove_socket(socket)
	end)
	messaging.loop():add_once(50, function ()
		messaging.connect('PUSH', 'work'):send('received after the script')
	end)
]]), 'received after the script')

-- scripts that never load messaging are unaffected
expect_equal(run_rascal_script([[print('plain')]]), 'plain')
