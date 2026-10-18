-- http server: some of what rascal.http can do, and a server to load test
--
--   rascal examples/http_server.lua [port] [worker_threads]     serve until stopped (default 8080, 4)
--   rascal examples/http_server.lua --test                       check every route, then exit
--
--   /                  a static page linking to everything below, from examples/http_static
--   /hello             text, handled in the server thread
--   /json              JSON, handled in the server thread
--   /user/<id>         a pattern capture
--   /slow              waits 20ms in the server thread before replying
--   /workers/hello     text, handled in one of the worker threads
--   /workers/json      JSON, handled in a worker thread
--   /workers/slow      waits 20ms in a worker thread before replying
--
-- Every request is a coroutine, so the slow routes only hold up their own
-- request, other requests carry on meanwhile. The worker threads are a
-- balanced service (see services.serve_balanced), each request going to the
-- worker with the fewest requests in progress.
--
-- To load test, eg. with wrk (https://github.com/wg/wrk):
--   wrk -t4 -c64 -d10s http://127.0.0.1:8080/hello
--   wrk -t4 -c64 -d10s http://127.0.0.1:8080/workers/hello
--   wrk -t4 -c256 -d10s http://127.0.0.1:8080/workers/slow

local http = require('rascal.http')
local threads = require('rascal.threads')

local test = arg[1] == '--test'
local port = (not test and tonumber(arg[1])) or 8080
local worker_threads = tonumber(arg[2]) or 4
local static_directory = (arg[0]:match('^(.*)/[^/]*$') or '.') .. '/http_static/'

-- handled in the server thread ---------------------------------------------------------------

local server = http.server()

server:equal('/hello', function (request)
	return http.text('hello ' .. (request.vars.name or 'world'))
end)

server:equal('/json', function (request)
	return http.json({ message = 'hello', time = os.time() })
end)

server:match('^/user/(%d+)$', function (request, context, user_id)
	return http.json({ user = tonumber(user_id) })
end)

server:equal('/slow', function (request)
	coroutine.yield(20)
	return http.text('waited')
end)

-- handled in worker threads ------------------------------------------------------------------

local workers = http.workers(worker_threads, function (worker_number)
	local http = require('rascal.http')
	return {
		http.equal('hello', http.text('hello from worker ' .. worker_number)),
		http.equal('json', function (request)
			return http.json({ message = 'hello', worker = worker_number })
		end),
		http.equal('slow', function (request)
			coroutine.yield(20)
			return http.text('waited in worker ' .. worker_number)
		end),
	}
end)
server:prefix('/workers/', workers)

-- static files, last so anything above is matched first
server:handle(http.static(static_directory))

-- serving ------------------------------------------------------------------------------------

if not test then
	log('serving http on http://127.0.0.1:' .. port .. '/ with ' .. worker_threads .. ' worker threads')
	server:listen('tcp://*:' .. port)
	return
end

-- in test mode, check each route from another thread (http.fetch blocks its
-- thread, so it cannot share one with the server), then stop
local endpoint = server:listen('tcp://127.0.0.1:*')
local done = require('rascal.messaging').bind('PULL', 'http_server.done')
loop:add_socket(done, function (socket)
	local result = socket:recv()
	loop:remove_socket(socket)
	socket:close()
	server:close()
	workers:close()
	if result ~= 'passed' then
		log(result)
		os.exit(1)
	end
	log('all routes passed')
end)

threads.start(function (port)
	local http = require('rascal.http')
	local base = 'http://127.0.0.1:' .. port
	local checks = {
		{ '/', 200, '<h1>rascal http server</h1>' },
		{ '/style.css', 200, 'font-family' },
		{ '/hello?name=test', 200, 'hello test' },
		{ '/json', 200, '"message":"hello"' },
		{ '/user/42', 200, '{"user":42}' },
		{ '/slow', 200, 'waited' },
		{ '/workers/hello', 200, 'hello from worker' },
		{ '/workers/json', 200, '"worker":' },
		{ '/workers/slow', 200, 'waited in worker' },
		{ '/missing', 404, 'Not Found' },
	}
	local result = 'passed'
	for _, check in ipairs(checks) do
		local path, status, contains = table.unpack(check)
		local response = http.fetch('GET', base .. path)
		if response.status ~= status or not response.body:find(contains, 1, true) then
			result = path .. ' returned ' .. response.status .. ': ' .. response.body
			break
		end
	end
	local push = require('rascal.messaging').connect('PUSH', 'http_server.done')
	push:send(result)
	push:close()
end, endpoint:match(':(%d+)$'))
