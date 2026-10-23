# HTTP server

[`examples/http_server.lua`](../../examples/http_server.lua): an HTTP server showing some of what [rascal.http](../modules/rascal.http.md) can do. It has routes handled in the server thread and in worker threads, slow routes, and static files. It's also set up for load testing.

```bash
rascal examples/http_server.lua                 # serve on port 8080, with 4 worker threads
rascal examples/http_server.lua 8081 8          # port and worker threads
rascal examples/http_server.lua --test          # check every route, then exit
```

Then open http://127.0.0.1:8080/ for a page linking to each route:

| | |
| --- | --- |
| `/` | a static page, from [`examples/http_static/`](../../examples/http_static) |
| `/hello` | text, handled in the server thread |
| `/json` | JSON, handled in the server thread |
| `/user/<id>` | a pattern capture |
| `/slow` | waits 20ms in the server thread before replying |
| `/workers/hello` | text, handled in one of the worker threads |
| `/workers/json` | JSON, handled in a worker thread |
| `/workers/slow` | waits 20ms in a worker thread before replying |

## What it shows

- **Handlers as values.** Routes are matchers wrapping functions, fixed responses, or lists of handlers.
- **A coroutine per request.** The slow routes wait with `coroutine.yield(20)`, which holds up only their own request. Other requests carry on meanwhile.
- **Worker threads with one change to the routing.** `http.workers` runs handlers in worker threads, as a [balanced service](../modules/rascal.services.md#servicesserve_balancedname-worker_count-api-worker-). Each request goes to the worker with the fewest requests in progress.
- **Static files** after the other routes, served from a directory.
- **Testing a server from another thread.** `--test` mode requests each route from a thread of its own, then stops the server.

## The source

### Settings

[Lines 25–31.](../../examples/http_server.lua#L25-L31) The port and number of worker threads come from the command line, unless it's `--test`. The static files are found beside the script, wherever it's run from:

```lua
local static_directory = (arg[0]:match('^(.*)/[^/]*$') or '.') .. '/http_static/'
```

### Routes in the server thread

[Lines 33–53.](../../examples/http_server.lua#L33-L53) Each route is a matcher on the server, wrapping a handler function:

```lua
local server = http.server()

server:equal('/hello', function (request)
	return http.text('hello ' .. (request.vars.name or 'world'))
end)

server:match('^/user/(%d+)$', function (request, context, user_id)
	return http.json({ user = tonumber(user_id) })
end)

server:equal('/slow', function (request)
	coroutine.yield(20)
	return http.text('waited')
end)
```

- **Query variables:** `request.vars` has the query's variables, eg. `/hello?name=test`.
- **Pattern captures:** a `server:match` pattern's captures are passed to the handler after the request and context.
- **Waiting:** `/slow` waits 20ms in its own coroutine, without blocking the server thread. Under load, many slow requests wait at once.

### Routes in worker threads

[Lines 55–69.](../../examples/http_server.lua#L55-L69) `http.workers` starts the worker threads. Its function runs in each worker, with the worker's number, and returns that worker's handler, here a list of routes:

```lua
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
```

The function runs in a new Lua state, so it requires `rascal.http` itself.

The workers are mounted under the `/workers/` prefix, which is removed from `request.path`. So the workers' routes match `hello`, rather than `/workers/hello`. The first route is a fixed response, made once in each worker and returned for every request.

Requests are passed to the workers as data, and their responses passed back. Each worker handles each request in a coroutine too, so `slow` waits without holding up others in the same worker.

### Static files

[Lines 71–72.](../../examples/http_server.lua#L71-L72) `http.static` serves the files in a directory. It's added last, so the routes above are matched first. A path with no file returns nil, so the server responds with 404.

```lua
server:handle(http.static(static_directory))
```

### Serving

[Lines 74–80.](../../examples/http_server.lua#L74-L80) Outside test mode, the server listens on the port, and the script ends:

```lua
server:listen('tcp://*:' .. port)
return
```

The server is in the main thread's loop, so the process keeps running, serving requests until it's stopped.

### Test mode

[Lines 82–97.](../../examples/http_server.lua#L82-L97) In test mode, the server listens on a free port, `tcp://127.0.0.1:*`, and `listen` returns the port it was given. The main thread then waits for a test result on an inproc PULL socket. When it arrives, it closes the socket, the server and the workers. With nothing left in its loop, the process exits, or exits with an error if the checks failed.

```lua
local endpoint = server:listen('tcp://127.0.0.1:*')
local done = require('rascal.messaging').bind('PULL', 'http_server.done')
loop:add_socket(done, function (socket)
	local result = socket:recv()
	loop:remove_socket(socket)
	socket:close()
	server:close()
	workers:close()
	...
end)
```

### Checking each route

[Lines 99–126.](../../examples/http_server.lua#L99-L126) The checks run in a thread of their own. `http.fetch` blocks its thread until the response arrives, so it can't call a server in the same thread. The thread fetches each route, and checks its status and some of its body:

```lua
local response = http.fetch('GET', base .. path)
if response.status ~= status or not response.body:find(contains, 1, true) then
	result = path .. ' returned ' .. response.status .. ': ' .. response.body
	break
end
```

It then pushes the result to the main thread.

## Load testing

With [wrk](https://github.com/wg/wrk), eg.:

```bash
wrk -t4 -c64 -d10s http://127.0.0.1:8080/hello
wrk -t4 -c64 -d10s http://127.0.0.1:8080/workers/hello
wrk -t4 -c256 -d10s http://127.0.0.1:8080/workers/slow
```

See [Performance](../technical/performance.md) for results, and why to measure on Linux.

## See also

- [rascal.http](../modules/rascal.http.md)
- [Guestbook](guestbook.md), a small web app with long polling
