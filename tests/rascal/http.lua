-- rascal.http: requests, responses, handlers, and a server over the network
local http = require('rascal.http')
local messaging = require('rascal.messaging')
local threads = require('rascal.threads')
local parser = require('rascal.http.parser')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

-- urls, queries and cookies
expect_equal(http.url_decode('a+b%20c%2Fd'), 'a b c/d')
expect_equal(http.url_encode('a b/c'), 'a%20b%2Fc')
local vars = http.parse_query('a=1&b=two+words&flag&c=%3D')
expect_equal(vars.a, '1')
expect_equal(vars.b, 'two words')
expect_equal(vars.flag, '')
expect_equal(vars.c, '=')
local cookies = http.parse_cookies('session=abc; theme=dark')
expect_equal(cookies.session, 'abc')
expect_equal(cookies.theme, 'dark')

-- parsing
expect_equal(parser.parse_request('GET / HTTP/1.1\r\nHost: x'), nil, 'incomplete')
expect_equal(parser.parse_request('NOT HTTP\r\n\r\n'), false, 'invalid')
local parsed = parser.parse_request('POST /a?b=1 HTTP/1.0\r\nHost: x\r\nX-A: 1\r\nx-a: 2\r\n\r\n')
expect_equal(parsed.method, 'POST')
expect_equal(parsed.version, '1.0')
expect_equal(parsed.headers['x-a'], '1, 2', 'repeated headers are joined')

-- responses
local from_number = http.response(404)
expect_equal(from_number.status, 404)
expect_equal(from_number.body, 'Not Found')
local from_string = http.response('<p>hi</p>')
expect_equal(from_string.status, 200)
expect_equal(from_string:get_header('Content-Type'), 'text/html; charset=utf-8')
local json = http.json({ a = 1 }, 201)
expect_equal(json.status, 201)
expect_equal(json.body, '{"a":1}')
-- a response passed between threads is plain data, http.response gives it methods again
local plain = { status = 303, headers = { Location = '/there' } }
local restored = http.response(plain)
expect_equal(restored:get_header('location'), '/there')
expect_equal(http.response(restored).status, 303, 'idempotent')
restored:set_status(302)
expect_equal(plain.status, 303, 'a new response, the original is unchanged')
local cookied = http.response()
cookied:add_header('Set-Cookie', 'a=1')
cookied:add_header('Set-Cookie', 'b=2')
expect_equal(#cookied.headers['set-cookie'], 2)
expect_error('a response is a status number', http.response, {})

-- handler forms
local function hello(request, context) return 'hello' end
local object = { handle = function (self, request, context) return 'from object' end }
local request = function (path)
	return http.request({ method = 'GET', path = path, full_path = path, headers = {}, vars = {} })
end
expect_equal(http.call(hello, request('/')), 'hello')
expect_equal(http.call(object, request('/')), 'from object')
expect_equal(http.call({ function () return nil end, hello }, request('/')), 'hello', 'lists fall through')
expect_equal(http.call({}, request('/')), nil)
local fixed = http.redirect('/elsewhere')
expect_equal(http.call(fixed, request('/')), fixed, 'a response is its own handler')
expect_equal(http.call(404, request('/')), 404, 'as are a status number and a string')
expect_error('a handler is a function', http.call, true, request('/'))

-- context is passed through, and created if not given
local seen_context = nil
http.call(function (request, context) seen_context = context end, request('/'))
expect_equal(type(seen_context), 'table')
local given = { user = 'someone' }
http.call({ function (request, context) seen_context = context end }, request('/'), given)
expect_equal(seen_context, given)

-- matchers
local routes = {
	http.equal('/', 'root'),
	http.prefix('/api/', {
		http.equal('items', function (request) return 'items at ' .. request.full_path end),
		http.match('^item/(%d+)/(%a+)$', function (request, context, id, part) return 'item ' .. id .. ' ' .. part end),
	}),
	function (request) return 'fallback for ' .. request.path end,
}
expect_equal(http.call(routes, request('/')), 'root')
expect_equal(http.call(routes, request('/api/items')), 'items at /api/items')
expect_equal(http.call(routes, request('/api/item/7/name')), 'item 7 name')
expect_equal(http.call(routes, request('/api/other')), 'fallback for /api/other', 'the prefix is restored when nothing inside handles it')

-- request methods
local post = http.request({ headers = { ['content-type'] = 'application/json' }, body = '{"x":[1,2]}' })
expect_equal(post:json().x[2], 2)
expect_equal(post:input().x[1], 1)
expect_equal(http.request({ headers = {}, body = '' }):json(), nil)

-- static files
local static_directory = os.tmpname()
os.remove(static_directory)
require('lfs').mkdir(static_directory)
local f = assert(io.open(static_directory .. '/index.html', 'w'))
f:write('<h1>index</h1>')
f:close()
f = assert(io.open(static_directory .. '/data.json', 'w'))
f:write('{}')
f:close()
local static = http.static(static_directory, { max_age = 60 })
expect_equal(static(request('/'), {}).body, '<h1>index</h1>')
local data = static(request('/data.json'), {})
expect_equal(data:get_header('content-type'), 'application/json')
expect_equal(data:get_header('cache-control'), 'max-age=60')
expect_equal(static(request('/missing.html'), {}), nil)
expect_equal(static(request('/../etc/passwd'), {}), nil, 'nothing outside the directory')
expect_equal(static(http.request({ method = 'POST', path = '/', headers = {} }), {}), nil)

-- a server over the network ----------------------------------------------------------------

local server = http.server()
server:equal('/hello', function (request) return http.text('hello ' .. (request.vars.name or 'world')) end)
server:equal('/echo', function (request) return http.text(request.method .. ' ' .. #request.body) end)
server:equal('/cookies', function (request)
	local response = http.text('cookies')
	response:add_header('set-cookie', 'a=1')
	response:add_header('set-cookie', 'b=2')
	return response
end)
server:equal('/close', function (request)
	return http.response('closing'):set_header('connection', 'close')
end)
server:equal('/fail', function () error('handler failure') end)
server:equal('/wait', function (request)
	coroutine.yield(tonumber(request.vars.ms))
	return http.text('waited ' .. request.vars.ms)
end)

-- worker threads, with middleware in this thread adding to the request (which travels) and the context (which does not)
local workers = http.workers(2, function (number)
	local http = require('rascal.http')
	return {
		http.equal('who', function (request, context)
			return http.json({ worker = number, user = request.user, context_user = context.user or false })
		end),
		http.equal('fail', function () error('worker failure') end),
		-- anything else is not handled here, so falls through to the server's next handler
	}
end)
server:prefix('/workers/', function (request, context, ...)
	request.user = 'travels'
	context.user = 'stays'
	return http.call(workers, request, context, ...)
end)
server:prefix('/workers/', 'fell through from the workers')

local endpoint = server:listen('tcp://127.0.0.1:*')
local results = messaging.bind('PULL', 'test_http_results')

threads.start(function (port)
	local http = require('rascal.http')
	local messaging = require('rascal.messaging')
	local cjson = require('cjson')
	local base = 'http://127.0.0.1:' .. port
	local report = {}

	local function get(path) return http.fetch('GET', base .. path) end

	report.hello = get('/hello?name=test').body
	report.missing = get('/missing').status
	report.fail = get('/fail').status
	report.post = http.fetch('POST', base .. '/echo', string.rep('x', 3000), { expect = '100-continue' }).body
	report.too_large = http.fetch('POST', base .. '/echo', string.rep('x', http.max_body_size + 1)).status
	local cookies = get('/cookies')
	report.cookies = cookies.headers['set-cookie']
	report.who = get('/workers/who'):json()
	report.worker_fail = get('/workers/fail').status
	report.fell_through = get('/workers/other').body

	-- a raw connection, for keep-alive, pipelining, HEAD and invalid requests
	local socket = messaging.socket('STREAM')
	socket:set_rcvtimeo(5000)
	socket:connect('tcp://127.0.0.1:' .. port)
	local id = socket:recv_all()[1]
	local function read_responses(count, head)
		local buffer = ''
		local statuses = {}
		while #statuses < count do
			local frames = socket:recv_all()
			if not frames or frames[2] == '' then break end
			buffer = buffer .. frames[2]
			while true do
				local response, length = require('rascal.http.parser').parse_response(buffer)
				if not response then break end
				-- a HEAD response has the length of the body it would have, without the body
				local body_length = head and 0 or tonumber(response.headers['content-length'] or '0')
				if #buffer < length + body_length then break end
				statuses[#statuses + 1] = response.status .. ' ' .. buffer:sub(length + 1, length + body_length)
				buffer = buffer:sub(length + body_length + 1)
			end
		end
		return statuses
	end
	-- two requests sent together are answered in order, even when the first takes longer
	socket:send_all({ id, 'GET /wait?ms=50 HTTP/1.1\r\nhost: x\r\n\r\nGET /wait?ms=1 HTTP/1.1\r\nhost: x\r\n\r\n' })
	report.pipelined = table.concat(read_responses(2), ', ')
	socket:send_all({ id, 'HEAD /hello HTTP/1.1\r\nhost: x\r\n\r\n' })
	report.head = table.concat(read_responses(1, true), ', ')
	socket:send_all({ id, 'NOT HTTP\r\n\r\n' })
	report.invalid = table.concat(read_responses(1), ', ')
	socket:close()

	-- a header that never ends
	socket = messaging.socket('STREAM')
	socket:set_rcvtimeo(5000)
	socket:connect('tcp://127.0.0.1:' .. port)
	id = socket:recv_all()[1]
	socket:send_all({ id, 'GET / HTTP/1.1\r\nx-long: ' .. string.rep('x', http.max_header_size + 10) })
	report.header_too_large = table.concat(read_responses(1), ', '):match('^%d+')
	socket:close()

	-- connection: close in a response closes the connection
	report.close = http.fetch('GET', base .. '/close').body

	local push = messaging.connect('PUSH', 'test_http_results')
	push:send(cjson.encode(report))
	push:close()
end, endpoint:match(':(%d+)$'))

-- the server runs on this thread's loop, so wait by running the loop
local message = nil
local started = messaging.utc_time()
while not message and messaging.utc_time() - started < 10 do
	loop:sleep_ex(10)
	message = results:recv(messaging.zmq.DONTWAIT)
end
results:close()
server:close()
workers:close()
local report = require('cjson').decode((assert(message, 'no report from the http client thread')))

expect_equal(report.hello, 'hello test')
expect_equal(report.missing, 404)
expect_equal(report.fail, 500)
expect_equal(report.post, 'POST 3000', 'a body sent after 100 continue')
expect_equal(report.too_large, 413)
expect_equal(report.cookies, 'a=1, b=2', 'two set-cookie headers, which the client joins')
expect_equal(report.who.worker == 1 or report.who.worker == 2, true)
expect_equal(report.who.user, 'travels', 'request fields travel to workers')
expect_equal(report.who.context_user, false, 'the context does not')
expect_equal(report.worker_fail, 500)
expect_equal(report.fell_through, 'fell through from the workers')
expect_equal(report.pipelined, '200 waited 50, 200 waited 1')
expect_equal(report.head, '200 ', 'a HEAD response has no body')
expect_equal(report.invalid, '400 Bad Request')
expect_equal(report.header_too_large, '431')
expect_equal(report.close, 'closing')

os.remove(static_directory .. '/index.html')
os.remove(static_directory .. '/data.json')
require('lfs').rmdir(static_directory)
