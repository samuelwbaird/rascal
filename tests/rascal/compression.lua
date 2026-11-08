-- rascal.http compression: gzip for http bodies, and permessage-deflate for websockets
local http = require('rascal.http')
local compression = require('rascal.http.compression')
local websocket = require('rascal.http.websocket')
local messaging = require('rascal.messaging')
local services = require('rascal.services')
local threads = require('rascal.threads')

local text = string.rep('compressible text, ', 200)

-- gzip and deflate round trips
local gzipped = compression.gzip(text)
assert(#gzipped < #text / 10, 'gzip compresses repeated text')
expect_equal(gzipped:sub(1, 2), '\31\139', 'gzip has its header')
expect_equal(compression.gunzip(gzipped, 100000), text)
local result, err = compression.gunzip(gzipped, 1000)
expect_equal(result, nil, 'gunzip has a size limit')
expect_equal(err, 'too large')
result, err = compression.gunzip('not gzip at all', 1000)
expect_equal(err, 'invalid compressed data')

local deflated = compression.deflate_message(text)
assert(deflated:sub(-4) ~= '\0\0\255\255', 'the empty block is removed from a message')
expect_equal(compression.inflate_message(deflated, 100000), text)
expect_equal(select(2, compression.inflate_message(deflated, 1000)), 'too large')

-- the example from RFC 7692, section 7.2.3.1
expect_equal(compression.inflate_message('\242\72\205\201\201\7\0', 100), 'Hello')

-- accept-encoding and content types
expect_equal(compression.accepts_gzip('gzip, deflate, br'), true)
expect_equal(compression.accepts_gzip('br;q=1.0, gzip;q=0.8'), true)
expect_equal(compression.accepts_gzip('gzip;q=0'), false)
expect_equal(compression.accepts_gzip('*'), true)
expect_equal(compression.accepts_gzip('identity'), false)
expect_equal(compression.accepts_gzip(nil), false)
expect_equal(compression.compressible('text/html; charset=utf-8'), true)
expect_equal(compression.compressible('application/json'), true)
expect_equal(compression.compressible('application/javascript'), true)
expect_equal(compression.compressible('image/png'), false)
expect_equal(compression.compressible(nil), false)

-- websocket frames: compressed messages are marked, and inflated by a reader that negotiated it
local frame = websocket.text_frame(text, true, true)
local read = websocket.read_frame(frame, 100000, true, true)
expect_equal(read.compressed, true, 'a large message is compressed')
assert(#read.payload < #text / 10)
expect_equal(websocket.read_frame(websocket.text_frame('{}', true, true), 100, true, true).compressed, false, 'a small message is not')
expect_equal(select(2, websocket.read_frame(frame, 100000, true, false)), websocket.PROTOCOL_ERROR, 'compressed without negotiating it')
local reader = websocket.reader(100000, true, true)
local events = reader.add(frame .. websocket.text_frame('{"a":1}', true, true))
expect_equal(events[1][2], text, 'a compressed message is inflated')
expect_equal(events[2][2], '{"a":1}')
expect_equal(websocket.reader(1000, true, true).add(frame)[1][2], websocket.TOO_BIG, 'a message too large once inflated')
local invalid = websocket.frame(websocket.TEXT, 'not deflate data', true, true)
expect_equal(websocket.reader(1000, true, true).add(invalid)[1][2], websocket.INVALID_DATA)

-- negotiating
expect_equal(websocket.accepts_deflate('permessage-deflate; client_max_window_bits'), true)
expect_equal(websocket.accepts_deflate('x-webkit-deflate-frame, permessage-deflate'), true)
expect_equal(websocket.accepts_deflate('permessage-deflate; server_max_window_bits=10'), false, 'a smaller window is not supported')
expect_equal(websocket.accepts_deflate(nil), false)

-- servers, with and without compression ---------------------------------------------------------

local senders = {}
local events_service = services.serve('test_compress.events', 'PULL', {
	opened = 'name:string, context:*',
	message = 'name:string, context:*, message:*',
	closed = 'name:string, context:*, code:number',
}, {
	opened = function () end,
	closed = function () end,
	message = function (self, name, context, message)
		senders[context.sender] = senders[context.sender] or services.connect(context.sender)
		senders[context.sender]:send(name, { echo = message.echo })
	end,
})

local function start(name, options)
	options.websockets = name .. '.send'
	local server = http.server(options)
	server:equal('/text', function () return http.text(text) end)
	server:equal('/small', function () return http.text('small') end)
	server:equal('/png', function () return http.response():set_body(text, 'image/png') end)
	server:equal('/encoded', function () return http.text(text):set_header('content-encoding', 'br') end)
	server:equal('/echo', function (request) return http.text(request.body) end)
	server:equal('/live', function (request)
		return http.websocket({ name = request.vars.name, service = 'test_compress.events', context = { sender = name .. '.send' } })
	end)
	return server, server:listen('tcp://127.0.0.1:*'):match(':(%d+)$')
end
local server, port = start('test_compress', {})
local plain, plain_port = start('test_compress_off', { compress = false, max_body_size = 2000 })

local results = messaging.bind('PULL', 'test_compress_results')
threads.start(function (port, plain_port, text)
	local http = require('rascal.http')
	local compression = require('rascal.http.compression')
	local websocket = require('rascal.http.websocket')
	local checks = {}
	local function check(condition, message)
		checks[#checks + 1] = (condition and 'ok ' or 'FAIL ') .. message
	end
	local base = 'http://127.0.0.1:' .. port
	local plain_base = 'http://127.0.0.1:' .. plain_port

	-- responses
	local response = http.fetch('GET', base .. '/text')
	check(response.headers['content-encoding'] == 'gzip', 'a text response is compressed')
	check(tonumber(response.headers['content-length']) < #text / 10, 'it is sent compressed')
	check(response.body == text, 'fetch decodes it')
	check(response.headers.vary == 'accept-encoding', 'it varies by accept-encoding')
	response = http.fetch('GET', base .. '/text', nil, { ['accept-encoding'] = 'identity' })
	check(not response.headers['content-encoding'] and response.body == text, 'not compressed when not accepted')
	check(response.headers.vary == 'accept-encoding', 'but it still varies by accept-encoding')
	check(not http.fetch('GET', base .. '/small').headers['content-encoding'], 'a small response is not compressed')
	check(not http.fetch('GET', base .. '/png').headers['content-encoding'], 'an image is not compressed')
	check(http.fetch('GET', base .. '/encoded').headers['content-encoding'] == 'br', 'an encoded response is left as it is')
	response = http.fetch('GET', plain_base .. '/text')
	check(not response.headers['content-encoding'] and response.body == text, 'a server with compress = false does not compress')

	-- request bodies
	local gzip_header = { ['content-encoding'] = 'gzip' }
	check(http.fetch('POST', base .. '/echo', compression.gzip(text), gzip_header).body == text, 'a gzip request body is decoded')
	check(http.fetch('POST', plain_base .. '/echo', compression.gzip(text), gzip_header).status == 413, 'a decoded body is limited to max_body_size')
	check(http.fetch('POST', base .. '/echo', 'not gzip', gzip_header).status == 400, 'an invalid gzip body is refused')
	check(http.fetch('POST', base .. '/echo', 'x', { ['content-encoding'] = 'br' }).status == 415, 'an unknown encoding is refused')

	-- websockets
	local client = websocket.connect('ws://127.0.0.1:' .. port .. '/live?name=a')
	check(client.deflate, 'deflate is negotiated')
	client:send({ echo = text })
	local reply = client:receive(5000)
	check(reply and reply.echo == text, 'a large message is compressed both ways')
	client:send({ echo = 'small' })
	reply = client:receive(5000)
	check(reply and reply.echo == 'small', 'a small message is sent as it is')
	client:close()

	client = websocket.connect('ws://127.0.0.1:' .. port .. '/live?name=b', nil, nil, { compress = false })
	check(not client.deflate, 'a client can choose not to offer deflate')
	client:send({ echo = text })
	reply = client:receive(5000)
	check(reply and reply.echo == text, 'and still sends and receives large messages')
	client:close()

	client = websocket.connect('ws://127.0.0.1:' .. plain_port .. '/live?name=c')
	check(not client.deflate, 'a server with compress = false does not accept deflate')
	client:close()

	local push = require('rascal.messaging').connect('PUSH', 'test_compress_results')
	push:send(table.concat(checks, '\n'))
	push:close()
end, port, plain_port, text)

-- the servers run on this thread's loop, so wait by running the loop
local message
wait_until(function ()
	message = results:recv(messaging.zmq.DONTWAIT)
	return message ~= nil
end, 30)
assert(message, 'the compression client thread did not finish')
for line in message:gmatch('[^\n]+') do
	assert(line:sub(1, 3) == 'ok ', line)
end

results:close()
server:close()
plain:close()
events_service:close()
