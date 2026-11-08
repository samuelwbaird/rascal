-- rascal.http websockets: the protocol, and a server with websockets over the network
local http = require('rascal.http')
local websocket = require('rascal.http.websocket')
local messaging = require('rascal.messaging')
local services = require('rascal.services')
local threads = require('rascal.threads')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

-- the handshake, from the example in RFC 6455
expect_equal(websocket.accept_key('dGhlIHNhbXBsZSBub25jZQ=='), 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=')

-- frames of each length, masked and not, read back
for _, size in ipairs({ 0, 5, 125, 126, 1000, 65535, 65536, 70000 }) do
	local payload = string.rep('x', size)
	for _, masked in ipairs({ false, true }) do
		local frame, rest = websocket.read_frame(websocket.frame(websocket.TEXT, payload, masked) .. 'more', 100000, masked)
		expect_equal(frame and frame.payload, payload, 'a frame of ' .. size .. ' bytes')
		expect_equal(rest, 'more')
	end
end
expect_equal(websocket.read_frame('\129', 100, false), nil, 'an incomplete frame')
local refused, code = websocket.read_frame(websocket.frame(websocket.TEXT, 'x', false), 100, true)
expect_equal(refused, false, 'an unmasked frame from a client')
expect_equal(code, websocket.PROTOCOL_ERROR)
refused, code = websocket.read_frame(websocket.frame(websocket.TEXT, string.rep('x', 200), true), 100, true)
expect_equal(code, websocket.TOO_BIG)

-- a reader assembles messages split across reads, and fragmented messages
local reader = websocket.reader(1000, true)
local bytes = websocket.frame(websocket.TEXT, '{"a":1}', true) .. websocket.frame(websocket.PING, 'p', true)
local events = reader.add(bytes:sub(1, 5))
expect_equal(#events, 0, 'nothing until a frame is complete')
events = reader.add(bytes:sub(6))
expect_equal(events[1][1], 'text')
expect_equal(events[1][2], '{"a":1}')
expect_equal(events[2][1], 'ping')
local first = string.char(0x01, 0x80 | 3) .. '\0\0\0\0' .. '{"b'			-- text, not final
local last = string.char(0x80, 0x80 | 4) .. '\0\0\0\0' .. '":2}'			-- continuation, final
events = reader.add(first .. last)
expect_equal(events[1][2], '{"b":2}', 'a fragmented message')
expect_equal(reader.add(websocket.frame(websocket.BINARY, 'x', true))[1][2], websocket.UNSUPPORTED)

-- a websocket response needs a name and a service
expect_error('needs a name', http.websocket, { service = 'x' })
expect_error('needs a name', http.websocket, {})
expect_error('needs the name of the service', http.websocket, { name = 'x' })
local accepted = http.websocket({ name = 'x', service = 'y', context = { user = 1 } })
expect_equal(accepted.status, 101)
expect_equal(http.response(accepted).websocket.context.user, 1, 'websocket details are kept by http.response')

-- a server with websockets ---------------------------------------------------------------------

-- the service receiving websocket events, in this thread, echoing messages back
local log_events = {}
local sender = nil
local events_service = services.serve('test_ws.events', 'PULL', {
	opened = 'name:string, context:*',
	message = 'name:string, context:*, message:*',
	closed = 'name:string, context:*, code:number',
}, {
	opened = function (self, name, context)
		log_events[#log_events + 1] = 'opened ' .. name .. ' ' .. tostring(context.user)
		if name == 'to_disconnect' then
			sender:disconnect(name, 4100, 'disconnected by the server')
		end
	end,
	message = function (self, name, context, message)
		log_events[#log_events + 1] = 'message ' .. name
		if message.echo then
			sender:send(name, { echo = message.echo, user = context.user })
		end
	end,
	closed = function (self, name, context, code)
		log_events[#log_events + 1] = 'closed ' .. name .. ' ' .. code
	end,
})

local server = http.server({ websockets = 'test_ws.send', websocket_timeout = 0.4 })
server:equal('/live', function (request)
	if not request.vars.name then
		return 403
	end
	return http.websocket({ name = request.vars.name, service = 'test_ws.events', context = { user = request.vars.name } })
end)
server:equal('/unserved', function (request)
	return http.websocket({ name = 'unserved', service = 'test_ws.nosuch' })
end)
local endpoint = server:listen('tcp://127.0.0.1:*')
sender = services.connect('test_ws.send')

local results = messaging.bind('PULL', 'test_ws_results')
threads.start(function (port)
	local http = require('rascal.http')
	local websocket = require('rascal.http.websocket')
	local base = 'ws://127.0.0.1:' .. port
	local checks = {}
	local function check(condition, message)
		checks[#checks + 1] = (condition and 'ok ' or 'FAIL ') .. message
	end

	-- a message is sent to the events service, which echoes it back
	local a = websocket.connect(base .. '/live?name=a')
	a:send({ echo = 'hello' })
	local reply = a:receive(5000)
	check(reply and reply.echo == 'hello' and reply.user == 'a', 'a message is echoed back with its context')

	-- a ping is answered, and the websocket carries on
	a:send_frame(websocket.PING, 'p')
	a:send({ echo = 'again' })
	reply = a:receive(5000)
	check(reply and reply.echo == 'again', 'the websocket carries on after a ping')

	-- refused upgrades
	local ok, err = pcall(websocket.connect, base .. '/live')
	check(not ok and err:find('status 403'), 'a handler refuses an upgrade with a status')
	ok, err = pcall(websocket.connect, base .. '/unserved')
	check(not ok and err:find('status 503'), 'an upgrade to a service that is not served is refused')
	local plain = http.fetch('GET', 'http://127.0.0.1:' .. port .. '/live?name=plain')
	check(plain.status == 400, 'a websocket response to a request that is not an upgrade is a bad request')

	-- a newer websocket with the same name replaces the older one
	local b1 = websocket.connect(base .. '/live?name=b')
	local b2 = websocket.connect(base .. '/live?name=b')
	b1:receive(2000)
	check(b1.closed and b1.closed.code == websocket.REPLACED, 'an older websocket is closed when replaced')
	b2:send({ echo = 'b2' })
	reply = b2:receive(5000)
	check(reply and reply.echo == 'b2', 'the newer websocket receives messages for the name')

	-- messages that are not json close the websocket
	local c = websocket.connect(base .. '/live?name=c')
	c:send('not json')
	c:receive(2000)
	check(c.closed and c.closed.code == websocket.INVALID_DATA, 'a message that is not json closes the websocket')
	local d = websocket.connect(base .. '/live?name=d')
	d:send_frame(websocket.BINARY, 'x')
	d:receive(2000)
	check(d.closed and d.closed.code == websocket.UNSUPPORTED, 'a binary message closes the websocket')

	-- the server can disconnect a websocket by name
	local e = websocket.connect(base .. '/live?name=to_disconnect')
	e:receive(2000)
	check(e.closed and e.closed.code == 4100 and e.closed.reason == 'disconnected by the server', 'the server disconnects a websocket by name')

	-- close these before the timeout check, during which they wouldn't answer pings
	a:close()
	b2:close()

	-- a websocket that doesn't answer pings is closed after the timeout
	local f = websocket.connect(base .. '/live?name=f')
	require('lzmq.timer').sleep(1000)
	f:receive(2000)
	check(f.closed and f.closed.code == websocket.GOING_AWAY, 'an idle websocket is closed after the timeout')

	local push = require('rascal.messaging').connect('PUSH', 'test_ws_results')
	push:send(table.concat(checks, '\n'))
	push:close()
end, endpoint:match(':(%d+)$'))

-- the server runs on this thread's loop, so wait by running the loop
local message
wait_until(function ()
	message = results:recv(messaging.zmq.DONTWAIT)
	return message ~= nil
end, 30)
assert(message, 'the websocket client thread did not finish')
for line in message:gmatch('[^\n]+') do
	assert(line:sub(1, 3) == 'ok ', line)
end

-- the events service saw each websocket open, its messages, and close
wait_until(function ()
	for _, event in ipairs(log_events) do
		if event == 'closed f 1001' then
			return true
		end
	end
end, 5)
local seen = {}
for _, event in ipairs(log_events) do
	seen[event] = true
end
assert(seen['opened a a'], 'opened with its context')
assert(seen['message a'], 'messages are sent to the service')
assert(seen['closed a 1000'], 'closed when the client closes')
assert(seen['closed b 4000'], 'closed when replaced')
assert(seen['closed b 1000'], 'the newer websocket closes normally')
assert(seen['closed c 1007'], 'closed for a message that is not json')
assert(seen['closed f 1001'], 'closed after the timeout')
assert(not seen['opened unserved nil'], 'a refused upgrade is never opened')

results:close()
server:close()
events_service:close()
