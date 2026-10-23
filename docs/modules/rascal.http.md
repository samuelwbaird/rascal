# rascal.http

An HTTP/1.1 server, with handlers that can run in the server's thread or in worker threads, and a minimal client. Source: [`lua/rascal/http.lua`](../../lua/rascal/http.lua).

```lua
local http = require('rascal.http')

local server = http.server()
server:equal('/', http.redirect('/hello'))
server:equal('/hello', function (request, context)
	return http.html('<h1>hello</h1>')
end)
server:prefix('/static/', http.static('public/'))
server:prefix('/api/', http.workers(4, function (worker_number)
	local http = require('rascal.http')
	return function (request, context)
		return http.json({ path = request.path, worker = worker_number })
	end
end))
server:listen('tcp://*:8080')
```

The server listens with a ZeroMQ STREAM socket, on its thread's loop, and parses requests with [picohttpparser](../dependencies.md#picohttpparser). Each request is handled in its own coroutine. So handlers can yield, wait with `loop:suspend` (eg. for long polling), or call services over DEALER connections, without holding up other requests.

There's no TLS: serve plain HTTP behind a proxy that terminates TLS. See [Architecture](../technical/architecture.md#http) for the design, and the [http_server](../examples/http_server.md) and [guestbook](../examples/guestbook.md) examples.

## Handlers

A handler is called as `handler(request, context, ...)`, and returns a response, or nil when it doesn't handle the request, so the next handler is tried. If no handler returns a response, the server responds with 404.

A handler can be any of these:

| | |
| --- | --- |
| a function | called with the request and context |
| a list of handlers | each is tried in order, until one returns a response |
| an object with a `handle` method | `object:handle(request, context, ...)` |
| a response | always returned as is, eg. `http.redirect('/')`, a string, or a status number |
| a matcher | `http.prefix`, `http.equal` or `http.match`, wrapping another handler |
| a remote handler | `http.service(name)` or `http.workers(count, build, ...)`, running in other threads |

The server itself is a list of handlers, tried in the order they're added.

**Middleware** is a handler that wraps others. It can change the request or context before calling them, or the response after. `http.response(value)` turns whatever a handler returned into a response object that can be changed:

```lua
local function with_session(handler)
	return function (request, context, ...)
		context.session = sessions:find(request.cookies.session) or sessions:create()
		local response = http.call(handler, request, context, ...)
		if response ~= nil then
			response = http.response(response)
			response:add_header('set-cookie', 'session=' .. context.session.id .. '; HttpOnly')
		end
		return response
	end
end

server:handle(with_session({
	http.equal('/', home_page),
	http.prefix('/account/', account_pages),
}))
```

An error raised by a handler is logged, with its stack trace, and the server responds with 500.

### http.call(handler, request, context, ...)

Calls a handler of any of the forms above, and returns its response, or nil. A new context is created if `context` is nil. Use this to call a handler from middleware.

### http.prefix(prefix, handler)

Handles requests whose path starts with `prefix`. The handler sees the rest of the path as `request.path`, and the full path is still `request.full_path`. Prefixes nest, each removing its part of the path.

### http.equal(path, handler)

Handles requests whose path is exactly `path`.

### http.match(pattern, handler)

Handles requests whose path matches a Lua pattern, passing its captures to the handler after the request and context.

```lua
server:match('^/posts/(%d+)$', function (request, context, id)
	return http.json(posts:get(tonumber(id)))
end)
```

### http.static(directory, options)

Serves the files in a directory, for GET and HEAD requests, using `request.path`, ie. the path after any prefix. It returns nil for anything else, and for files that don't exist, so other handlers can follow it.

- **Content type:** set from the file's extension, see `http.mime_types`.
- **Safe paths:** paths that would reach outside the directory, eg. with `..`, aren't served.

Options:

| | |
| --- | --- |
| `index` | the file for paths ending in `/`, by default `index.html` |
| `max_age` | sets `cache-control: max-age=<seconds>`, for browsers to cache files |
| `cache_seconds` | keeps files in memory for that many seconds after they're read. It's off by default. Cached files are in a weak table, so they're also let go whenever the garbage collector runs |

## Requests

A request is a table, with these fields:

| | |
| --- | --- |
| `method` | eg. `'GET'` |
| `full_path` | the path, without the query |
| `path` | the path after any prefixes, see `http.prefix` |
| `query` | the query string, or nil |
| `vars` | the query's variables, decoded, eg. `{ page = '2' }` |
| `headers` | the headers, with lower case names |
| `cookies` | the cookies, eg. `{ session = 'abc' }` |
| `body` | the body as a string, `''` if there's none |
| `version` | `'1.1'` or `'1.0'` |
| `keep_alive` | whether the connection stays open after the response |

A request travels as data, to worker threads and back to the server's thread. So anything a handler adds to it must be a plain value, see [values](rascal.messaging.md#values). Live objects belong in the context.

### request:header(name)

A header's value, by a name in any case.

### request:json(), request:msgpack()

The body decoded as JSON or MessagePack, or nil if there's no body.

### request:input()

The body decoded as MessagePack if the request's content type says so, otherwise as JSON.

### http.request(data)

Makes a request from its data, eg. one passed to another thread. Remote handlers do this automatically.

## Context

The context is a table for one request in one thread, for live objects such as a database connection, a session, or the current user. Each thread a request reaches gives it a fresh context. It's never passed between threads.

## Responses

A handler can return any of these:
- **a status number**, eg. `404`, with the status text as a plain text body
- **a string**, as an HTML page
- **a response object**, from the functions below

| | |
| --- | --- |
| `http.response(value)` | a new response object from a status number, a string, or a response, or an empty 200 response if `value` is nil |
| `http.json(value, status)` | a JSON response |
| `http.html(text, status)` | an HTML response |
| `http.text(text, status)` | a plain text response |
| `http.redirect(location, status)` | a redirect, by default `303 See Other` |

`status` defaults to 200. `http.response` always makes a new object, so changing it never changes the value it was made from, eg. a response shared by many requests.

### Response objects

A response has `status`, `headers` (with lower case names) and `body` fields. Its methods each return the response, so they can be chained:

| | |
| --- | --- |
| `response:set_status(status)` | |
| `response:set_header(name, value)` | sets a header, or removes it if `value` is nil |
| `response:add_header(name, value)` | adds a header that can be given more than once, eg. `set-cookie` |
| `response:get_header(name)` | a header's value, a list for one added more than once |
| `response:set_body(body, content_type)` | |
| `response:set_json(value)` | the body as JSON |
| `response:set_output(value, request)` | the body as MessagePack if the request accepts it, otherwise as JSON |
| `response:set_mimetype_from_extension(extension)` | the content type for a file extension, eg. `'png'` |
| `response:redirect(location, status)` | |
| `response:json()` | the body decoded as JSON, eg. for a response from `http.fetch` |

The server sets `content-length` and `connection` itself. A response with `connection: close` closes the connection after it's sent.

## Handlers in other threads

A handler in another thread runs as a service, so the request is passed to it as data and its response passed back. Match captures are passed on with the request; the context isn't.

### http.workers(count, build, ...)

A handler that spreads requests across `count` worker threads, using [services.serve_balanced](rascal.services.md#servicesserve_balancedname-worker_count-api-worker-). `build` is thread code, a function or a string. It runs in each worker thread with the worker's number and any further arguments, and returns the handler for that worker.

Use workers for slow or CPU-bound handlers, so they don't hold up the server's thread. The result is a handler object, with `close()` to stop the workers.

### http.serve(name, handler)

Serves a handler as a named service in this thread, for `http.service(name)` to call from another thread. It's served as ROUTER, so the handler can yield. Use it to give some part of a site a thread of its own, eg. one that owns a database.

### http.service(name)

A handler that passes requests to a service served with `http.serve` or `http.workers`. It connects with DEALER, so only the request's coroutine waits for the response.

### http.handler_object(handler)

The object that `http.serve` and `http.workers` serve: its `handle` method calls the handler with the request from another thread and a fresh context.

## The server

### http.server(options)

A new server. Options change these defaults for this server:

| Option | Default | |
| --- | --- | --- |
| `max_header_size` | 64KB | larger request headers are rejected with 431 |
| `max_body_size` | 1MB | larger request bodies are rejected with 413 |
| `keep_alive_timeout` | 60 | seconds an idle connection is kept open, or `false` to keep idle connections open |

The defaults are `http.max_header_size`, `http.max_body_size` and `http.keep_alive_timeout`, and can be changed for every server.

### server:handle(handler)

Adds a handler, returning the server. `server:prefix(prefix, handler)`, `server:equal(path, handler)` and `server:match(pattern, handler)` add a handler wrapped in a matcher.

### server:listen(endpoint)

Listens on a network endpoint, eg. `'tcp://*:8080'`, and returns the endpoint, with any wildcard port resolved: `'tcp://127.0.0.1:*'` listens on a free port.

The server is in its thread's loop, so the thread keeps running until the server is closed.

### server:close()

Stops listening, and closes every connection.

### Connections

- **Keep-alive:** connections stay open between requests, unless the client asks to close them or uses HTTP/1.0 without asking to keep them.
- **Ordering:** requests on one connection are handled one at a time, in order. Requests on different connections are handled at the same time.
- **Request bodies:** a request with `expect: 100-continue` is told to continue. Chunked request bodies aren't supported, and are rejected with 411.
- **Slow readers:** sending never blocks the server's thread. A connection that isn't reading what's been sent to it is closed.

## The client

### http.fetch(method, url, body, headers, timeout)

Makes a plain HTTP request, and returns the response, with `status`, `headers` (with lower case names), `body`, and `response:json()`.

```lua
local response = http.fetch('POST', 'http://127.0.0.1:8080/api/posts', '{"text":"hi"}', { ['content-type'] = 'application/json' })
print(response.status, response:json().id)
```

It's a minimal client, for tests and local services:
- **Blocking:** it blocks its thread until the response arrives, so never call a server running in the same thread.
- **Timeout:** it raises an error after `timeout` milliseconds, 10000 by default.
- **Plain HTTP only:** it supports `http://` URLs, with no TLS, redirects or chunked responses.

## Utilities

| | |
| --- | --- |
| `http.url_encode(text)`, `http.url_decode(text)` | |
| `http.parse_query(query)` | the variables in a query string, eg. `'a=1&b=two'` as `{ a = '1', b = 'two' }` |
| `http.parse_cookies(header)` | the cookies in a cookie header |
| `http.status_text` | the text for each status number |
| `http.mime_types` | the content type for each file extension, which can be added to |
