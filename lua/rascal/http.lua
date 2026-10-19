-- http — an HTTP server, with handlers that can run in this thread or in worker threads
--
-- local http = require('rascal.http')
-- local server = http.server()
-- server:equal('/', http.redirect('/hello'))
-- server:equal('/hello', function (request, context)
--     return http.html('<h1>hello</h1>')
-- end)
-- server:prefix('/static/', http.static('public/'))
-- server:prefix('/api/', http.workers(4, function (worker_number)
--     local http = require('rascal.http')
--     return function (request, context) return http.json({ path = request.path }) end
-- end))
-- server:listen('tcp://*:8080')
--
-- :: handlers
--   handler(request, context, ...) returns a response, or nil when it does not
--   handle the request, so the next handler is tried. A handler can be:
--     a function
--     a list of handlers, tried in order
--     an object with a handle(request, context, ...) method
--     a response, always returned as is (eg. http.redirect('/somewhere'),
--       a string, or a status number)
--     a matcher wrapping a handler: http.prefix, http.equal, http.match
--     a remote handler: http.service(name) or http.workers(count, build, ...)
--   server:prefix(p, h) is the same as server:handle(http.prefix(p, h)), and
--   so on, the server is a list of handlers in the order they are added.
--
-- :: requests
--   method, full_path, path (after any prefix), query, vars (from the query),
--   headers (lower case names), cookies, body, version, keep_alive
--   methods: request:json(), request:msgpack(), request:input(), request:header(name)
--   A request travels as data, to worker threads and back to this thread's
--   handlers, so anything added to it must be a plain value.
--
-- :: context
--   A table for this request in this thread, for live objects such as a
--   session or the current user. Each thread a request reaches gives it a
--   fresh context, it is never passed between threads.
--
-- :: responses
--   A handler can return a status number, a string (as html), or a response,
--   from http.response(), http.json(value), http.html(text), http.text(text)
--   or http.redirect(location). http.response(value) turns any of these into a
--   response object, with methods to change it (set_status, set_header,
--   add_header, get_header, set_body, set_json, set_mimetype_from_extension,
--   redirect, set_output), which is how middleware adds to a response.
--
-- Each request is handled in a coroutine, so handlers can yield, suspend
-- (eg. for long polling) or call other services with DEALER connections.
-- Requests on one connection are handled one at a time, in order.
--
-- http.fetch(method, url, body, headers) is a minimal plain HTTP client, for
-- tests and local services. It blocks its thread.

local prelude = require('prelude')
local cjson = require('cjson')
local cmsgpack = require('cmsgpack')
local parser = require('rascal.http.parser')
local messaging = require('rascal.messaging')
local services = require('rascal.services')
local threads = require('rascal.threads')

local log = rawget(_G, 'log') or print

local http = {}

-- defaults for servers, each can be changed for one server with http.server(options)
http.max_header_size = 64 * 1024	-- bytes
http.max_body_size = 1024 * 1024	-- bytes
http.keep_alive_timeout = 60		-- seconds an idle connection is kept open, or false to keep them

http.status_text = {
	[100] = 'Continue', [101] = 'Switching Protocols',
	[200] = 'OK', [201] = 'Created', [202] = 'Accepted', [204] = 'No Content',
	[301] = 'Moved Permanently', [302] = 'Found', [303] = 'See Other', [304] = 'Not Modified',
	[307] = 'Temporary Redirect', [308] = 'Permanent Redirect',
	[400] = 'Bad Request', [401] = 'Unauthorized', [403] = 'Forbidden', [404] = 'Not Found',
	[405] = 'Method Not Allowed', [408] = 'Request Timeout', [411] = 'Length Required',
	[413] = 'Content Too Large', [429] = 'Too Many Requests', [431] = 'Request Header Fields Too Large',
	[500] = 'Internal Server Error', [501] = 'Not Implemented', [502] = 'Bad Gateway',
	[503] = 'Service Unavailable', [504] = 'Gateway Timeout',
}

http.mime_types = {
	html = 'text/html; charset=utf-8', htm = 'text/html; charset=utf-8',
	css = 'text/css; charset=utf-8', js = 'text/javascript; charset=utf-8', mjs = 'text/javascript; charset=utf-8',
	json = 'application/json', map = 'application/json', msgpack = 'application/msgpack',
	txt = 'text/plain; charset=utf-8', xml = 'application/xml', svg = 'image/svg+xml',
	png = 'image/png', jpg = 'image/jpeg', jpeg = 'image/jpeg', gif = 'image/gif', webp = 'image/webp',
	ico = 'image/x-icon', woff = 'font/woff', woff2 = 'font/woff2', ttf = 'font/ttf',
	pdf = 'application/pdf', wasm = 'application/wasm', mp3 = 'audio/mpeg', mp4 = 'video/mp4', webm = 'video/webm',
}

-- urls, queries and cookies ------------------------------------------------------------------

function http.url_decode(text)
	text = text:gsub('+', ' ')
	return (text:gsub('%%(%x%x)', function (hex) return string.char(tonumber(hex, 16)) end))
end

function http.url_encode(text)
	return (text:gsub('[^%w%-%._~]', function (c) return string.format('%%%02X', c:byte()) end))
end

-- the variables in a query string, eg. 'a=1&b=two' as { a = '1', b = 'two' }
function http.parse_query(query)
	local vars = {}
	for pair in query:gmatch('[^&]+') do
		local name, value = pair:match('^([^=]*)=?(.*)$')
		vars[http.url_decode(name)] = http.url_decode(value)
	end
	return vars
end

-- the cookies in a cookie header, eg. 'a=1; b=2' as { a = '1', b = '2' }
function http.parse_cookies(header)
	local cookies = {}
	if header then
		for name, value in header:gmatch('%s*([^=;]+)=([^;]*)') do
			cookies[name] = value
		end
	end
	return cookies
end

-- requests -----------------------------------------------------------------------------------

local request_class = prelude.class()
http.request_class = request_class

-- a request from its data, eg. as it arrives in a worker thread
function http.request(data)
	return setmetatable(data, request_class)
end

function request_class:header(name)
	return self.headers[name:lower()]
end

-- the body decoded as JSON, nil if there is no body
function request_class:json()
	if self.body and self.body ~= '' then
		return cjson.decode(self.body)
	end
end

function request_class:msgpack()
	if self.body and self.body ~= '' then
		return cmsgpack.unpack(self.body)
	end
end

-- the body decoded by its content type, JSON unless it is msgpack
function request_class:input()
	local content_type = self.headers['content-type'] or ''
	if content_type:find('msgpack', 1, true) then
		return self:msgpack()
	end
	return self:json()
end

local function build_request(parsed, body)
	local headers = parsed.headers
	local path, query = parsed.path:match('^([^?#]*)%??([^#]*)')
	local connection = (headers.connection or ''):lower()
	local keep_alive
	if parsed.version == '1.0' then
		keep_alive = connection:find('keep-alive', 1, true) ~= nil
	else
		keep_alive = connection:find('close', 1, true) == nil
	end
	return http.request({
		method = parsed.method,
		version = parsed.version,
		full_path = path,
		path = path,
		query = query ~= '' and query or nil,
		vars = query ~= '' and http.parse_query(query) or {},
		headers = headers,
		cookies = http.parse_cookies(headers.cookie),
		body = body,
		keep_alive = keep_alive,
	})
end

-- responses ----------------------------------------------------------------------------------

local response_class = prelude.class()
http.response_class = response_class

function response_class:init(status)
	self.status = status or 200
	self.headers = {}
end

function response_class:set_status(status)
	self.status = status
	return self
end

function response_class:set_header(name, value)
	self.headers[name:lower()] = value ~= nil and tostring(value) or nil
	return self
end

-- add a header that can be given more than once, eg. set-cookie
function response_class:add_header(name, value)
	name = name:lower()
	local existing = self.headers[name]
	if existing == nil then
		self.headers[name] = tostring(value)
	elseif type(existing) == 'table' then
		existing[#existing + 1] = tostring(value)
	else
		self.headers[name] = { existing, tostring(value) }
	end
	return self
end

function response_class:get_header(name)
	return self.headers[name:lower()]
end

function response_class:set_body(body, content_type)
	self.body = body ~= nil and tostring(body) or nil
	if content_type then
		self.headers['content-type'] = content_type
	end
	return self
end

function response_class:set_mimetype_from_extension(extension)
	local mime_type = http.mime_types[extension:lower()]
	if mime_type then
		self.headers['content-type'] = mime_type
	end
	return self
end

function response_class:set_json(value)
	return self:set_body(cjson.encode(value), http.mime_types.json)
end

-- set the body as msgpack if the request accepts it, otherwise as JSON
function response_class:set_output(value, request)
	local accept = request and request.headers.accept or ''
	if accept:find('msgpack', 1, true) then
		return self:set_body(cmsgpack.pack(value), http.mime_types.msgpack)
	end
	return self:set_json(value)
end

function response_class:redirect(location, status)
	self.status = status or 303
	self.headers.location = location
	return self
end

-- the body decoded as JSON, eg. for a response from http.fetch
function response_class:json()
	if self.body and self.body ~= '' then
		return cjson.decode(self.body)
	end
end

-- a response object from a status number, a string (as html), or a response
-- (including one passed back from another thread). Always a new object, so
-- it can be changed without changing what it was made from
function http.response(value)
	local value_type = type(value)
	if value == nil then
		return response_class()
	elseif value_type == 'number' then
		local response = response_class(value)
		response.body = http.status_text[value] or ''
		response.headers['content-type'] = http.mime_types.txt
		return response
	elseif value_type == 'string' then
		return response_class():set_body(value, http.mime_types.html)
	elseif value_type == 'table' and type(value.status) == 'number' then
		local response = response_class(value.status)
		for name, header in pairs(value.headers or {}) do
			if type(header) == 'table' then
				header = table.move(header, 1, #header, 1, {})
			end
			response.headers[name:lower()] = header
		end
		response.body = value.body
		return response
	end
	error('http: a response is a status number, a string or a response table, not ' .. tostring(value), 2)
end

function http.json(value, status)
	return response_class(status):set_json(value)
end

function http.html(text, status)
	return response_class(status):set_body(text, http.mime_types.html)
end

function http.text(text, status)
	return response_class(status):set_body(text, http.mime_types.txt)
end

function http.redirect(location, status)
	return response_class():redirect(location, status)
end

local no_body_status = { [204] = true, [304] = true }

-- the bytes of a response, sent to the client
local function response_bytes(response, request, keep_alive)
	local body = response.body or ''
	local status = response.status
	local lines = {
		'HTTP/1.1 ' .. status .. ' ' .. (http.status_text[status] or ''),
	}
	for name, value in pairs(response.headers) do
		if name ~= 'content-length' and name ~= 'connection' then
			if type(value) == 'table' then
				for _, each in ipairs(value) do
					lines[#lines + 1] = name .. ': ' .. each
				end
			else
				lines[#lines + 1] = name .. ': ' .. value
			end
		end
	end
	if no_body_status[status] or status < 200 then
		body = ''
	else
		lines[#lines + 1] = 'content-length: ' .. #body
	end
	lines[#lines + 1] = keep_alive and 'connection: keep-alive' or 'connection: close'
	if request and request.method == 'HEAD' then
		body = ''
	end
	return table.concat(lines, '\r\n') .. '\r\n\r\n' .. body
end

-- handlers -----------------------------------------------------------------------------------

-- call a handler of any form, returning its response, or nil if it does not
-- handle the request. A context is created if none is given
function http.call(handler, request, context, ...)
	context = context or {}
	local handler_type = type(handler)
	if handler_type == 'function' then
		return handler(request, context, ...)
	elseif handler_type == 'string' or handler_type == 'number' then
		return handler
	elseif handler_type == 'table' then
		if type(handler.handle) == 'function' then
			return handler:handle(request, context, ...)
		elseif type(handler.status) == 'number' then
			return handler
		end
		for _, each in ipairs(handler) do
			local response = http.call(each, request, context, ...)
			if response ~= nil then
				return response
			end
		end
		return nil
	end
	error('http: a handler is a function, a list of handlers, an object with a handle method or a response, not ' .. tostring(handler), 2)
end

-- handle requests whose path starts with prefix, with the rest of the path as request.path
function http.prefix(prefix, handler)
	return function (request, context, ...)
		local path = request.path
		if path:sub(1, #prefix) ~= prefix then
			return nil
		end
		request.path = path:sub(#prefix + 1)
		local response = http.call(handler, request, context, ...)
		request.path = path
		return response
	end
end

-- handle requests whose path is exactly path
function http.equal(path, handler)
	return function (request, context, ...)
		if request.path == path then
			return http.call(handler, request, context, ...)
		end
	end
end

-- handle requests whose path matches a Lua pattern, passing its captures to the handler
function http.match(pattern, handler)
	return function (request, context, ...)
		local captures = table.pack(request.path:match(pattern))
		if captures[1] == nil then
			return nil
		end
		local args = table.pack(...)
		table.move(captures, 1, captures.n, args.n + 1, args)
		return http.call(handler, request, context, table.unpack(args, 1, args.n + captures.n))
	end
end

-- serve the files in a directory, for GET and HEAD requests, using
-- request.path (after any prefix). options:
--   index           the file for paths ending in / (default index.html)
--   max_age         sets cache-control, for the browser to cache files
--   cache_seconds   keeps files in memory for that many seconds after they are
--                   read (off by default), in a weak table, so a cached file
--                   is also let go whenever the garbage collector runs
function http.static(directory, options)
	options = options or {}
	local index = options.index or 'index.html'
	if directory:sub(-1) ~= '/' then
		directory = directory .. '/'
	end
	-- filename -> { contents, expires }
	local cache = options.cache_seconds and setmetatable({}, { __mode = 'v' })
	return function (request, context)
		if request.method ~= 'GET' and request.method ~= 'HEAD' then
			return nil
		end
		local path = http.url_decode(request.path):gsub('^/+', '')
		if path == '' or path:sub(-1) == '/' then
			path = path .. index
		end
		-- nothing outside the directory
		if path:find('%z') or ('/' .. path .. '/'):find('/%.%./') then
			return nil
		end
		local filename = directory .. path
		local cached = cache and cache[filename]
		local contents
		if cached and cached.expires > messaging.utc_time() then
			contents = cached.contents
		else
			local file = io.open(filename, 'rb')
			if not file then
				return nil
			end
			contents = file:read('a')
			file:close()
			if not contents then
				return nil -- eg. a directory
			end
			if cache then
				cache[filename] = { contents = contents, expires = messaging.utc_time() + options.cache_seconds }
			end
		end
		local response = response_class():set_body(contents)
		response:set_mimetype_from_extension(path:match('%.([^%./]+)$') or '')
		if options.max_age then
			response.headers['cache-control'] = 'max-age=' .. options.max_age
		end
		return response
	end
end

-- remote handlers ----------------------------------------------------------------------------

local handler_api = {
	handle = 'request:table, ... -> response:*',
}

-- an object serving a handler as a service, as the request arrives from another thread
function http.handler_object(handler)
	return {
		handle = function (self, request, ...)
			local response = http.call(handler, http.request(request), {}, ...)
			if response ~= nil then
				response = http.response(response)
			end
			return response
		end,
	}
end

-- serve a handler as a named service in this thread, for http.service(name)
-- in another thread, eg. to give some part of a site a thread of its own
function http.serve(name, handler)
	return services.serve(name, 'ROUTER', handler_api, http.handler_object(handler))
end

-- a handler that passes requests to a named service, served with
-- http.serve or http.workers. Any match captures are passed on, the
-- context is not
function http.service(name)
	local connection = nil
	return function (request, context, ...)
		if not connection then
			connection = services.connect(name, 'DEALER')
		end
		return connection:handle(request, ...)
	end
end

-- each worker thread of http.workers starts here
local function http_worker(number, build, ...)
	local http = require('rascal.http')
	local handler = require('rascal.threads').load(build)(number, ...)
	return http.handler_object(handler)
end

local workers_count = 0

-- a handler that spreads requests across worker threads, see
-- services.serve_balanced. build is a function or source, run in each worker
-- thread with the worker's number and any further arguments, returning the
-- handler for that worker. Returns a handler object, with close() to stop
-- the workers
function http.workers(count, build, ...)
	workers_count = workers_count + 1
	local name = string.format('rascal.http.workers.%p.%d', http, workers_count)
	local service = services.serve_balanced(name, count, handler_api, http_worker, threads.code(build, 2), ...)
	local forward = http.service(name)
	return {
		handle = function (self, request, context, ...)
			return forward(request, context, ...)
		end,
		close = function ()
			service:close()
		end,
	}
end

-- the server ---------------------------------------------------------------------------------

local server_class = prelude.class()

local server_options = {
	max_header_size = true,
	max_body_size = true,
	keep_alive_timeout = true,
}

-- a server, with options to change the defaults above for this server
-- (max_header_size, max_body_size, keep_alive_timeout)
function http.server(options)
	options = options or {}
	if type(options) ~= 'table' then
		error('http: http.server takes a table of options', 2)
	end
	for name in pairs(options) do
		if not server_options[name] then
			error('http: unknown server option ' .. tostring(name), 2)
		end
	end
	return server_class(options)
end

function server_class:init(options)
	self.handlers = prelude.list()
	self.connections = {}
	self.max_header_size = options.max_header_size or http.max_header_size
	self.max_body_size = options.max_body_size or http.max_body_size
	if options.keep_alive_timeout ~= nil then
		self.keep_alive_timeout = options.keep_alive_timeout
	else
		self.keep_alive_timeout = http.keep_alive_timeout
	end
end

function server_class:handle(handler)
	self.handlers:push(handler)
	return self
end

function server_class:prefix(prefix, handler)
	return self:handle(http.prefix(prefix, handler))
end

function server_class:equal(path, handler)
	return self:handle(http.equal(path, handler))
end

function server_class:match(pattern, handler)
	return self:handle(http.match(pattern, handler))
end

-- listen for connections on a network endpoint, eg. 'tcp://*:8080',
-- returning the endpoint (with any wildcard port resolved)
function server_class:listen(endpoint)
	if self.socket then
		error('http: the server is already listening', 2)
	end
	local socket = messaging.bind_network('STREAM', endpoint)
	-- never block this thread on one connection, a connection that cannot
	-- take more data is closed instead (see send)
	socket:set_sndtimeo(0)
	self.socket = socket
	messaging.loop():add_socket(socket, function (socket)
		local frames = socket:recv_all()
		self:receive(frames[1], frames[2])
	end)
	-- close connections that have been idle too long, checking every second,
	-- or more often for a short timeout
	if self.keep_alive_timeout then
		local interval = math.max(10, math.min(1000, self.keep_alive_timeout * 500))
		self.idle_timer = messaging.loop():add_interval(interval, function ()
			self:close_idle()
		end)
	end
	-- lzmq includes the terminating zero byte of the endpoint
	self.endpoint = socket:get_last_endpoint():gsub('%z$', '')
	return self.endpoint
end

-- close connections with no request in progress, that have had nothing
-- sent or received for longer than the keep-alive timeout
function server_class:close_idle()
	local now = messaging.utc_time()
	for _, connection in pairs(self.connections) do
		if not connection.busy and now - connection.active > self.keep_alive_timeout then
			self:close_connection(connection)
		end
	end
end

-- stop listening, and close every connection
function server_class:close()
	if not self.socket then
		return
	end
	messaging.loop():remove_socket(self.socket)
	self.socket:close()
	self.socket = nil
	if self.idle_timer then
		self.idle_timer:reset()
		self.idle_timer = nil
	end
	for _, connection in pairs(self.connections) do
		connection.closed = true
	end
	self.connections = {}
end

-- data from a connection, an empty message when a connection opens or closes
function server_class:receive(id, data)
	local connection = self.connections[id]
	if data == '' then
		if connection then
			connection.closed = true
			self.connections[id] = nil
		else
			self.connections[id] = { id = id, buffer = '', busy = false, closed = false, active = messaging.utc_time() }
		end
		return
	end
	if not connection or connection.closing then
		return
	end
	connection.active = messaging.utc_time()
	connection.buffer = connection.buffer .. data
	if not connection.busy then
		self:next_request(connection)
	end
end

function server_class:send(connection, bytes)
	if self.socket and not connection.closed and not connection.closing then
		if not self.socket:send_all({ connection.id, bytes }) then
			-- the client is not reading what was already sent, or has gone
			self:close_connection(connection)
		end
	end
end

function server_class:close_connection(connection)
	if self.socket and not connection.closed and not connection.closing then
		connection.closing = true
		self.socket:send_all({ connection.id, '' })
	end
end

-- respond with an error status and close the connection
function server_class:reject(connection, status)
	self:send(connection, response_bytes(http.response(status), nil, false))
	self:close_connection(connection)
end

-- handle the next complete request on a connection, if there is one
function server_class:next_request(connection)
	local buffer = connection.buffer
	if buffer == '' then
		return
	end
	local parsed, header_length = parser.parse_request(buffer)
	if parsed == nil then
		if #buffer > self.max_header_size then
			self:reject(connection, 431)
		end
		return
	elseif parsed == false then
		self:reject(connection, 400)
		return
	elseif header_length > self.max_header_size then
		self:reject(connection, 431)
		return
	end

	local headers = parsed.headers
	local encoding = headers['transfer-encoding']
	if encoding and encoding:lower() ~= 'identity' then
		-- chunked request bodies are not supported
		self:reject(connection, 411)
		return
	end
	local length = tonumber(headers['content-length'] or '0')
	if not length or length < 0 or math.type(length) ~= 'integer' then
		self:reject(connection, 400)
		return
	elseif length > self.max_body_size then
		self:reject(connection, 413)
		return
	end
	if #buffer < header_length + length then
		-- wait for the rest of the body, telling the client to send it if it asked
		if not connection.continued and (headers.expect or ''):lower() == '100-continue' then
			connection.continued = true
			self:send(connection, 'HTTP/1.1 100 Continue\r\n\r\n')
		end
		return
	end

	connection.buffer = buffer:sub(header_length + length + 1)
	connection.continued = false
	connection.busy = true
	local request = build_request(parsed, buffer:sub(header_length + 1, header_length + length))
	messaging.loop():schedule(function ()
		self:respond(connection, request)
	end)
end

local function traceback(err)
	return debug.traceback(tostring(err), 2)
end

-- handle a request, in its own coroutine, and send the response
function server_class:respond(connection, request)
	local ok, response = xpcall(http.call, traceback, self.handlers, request, {})
	if ok then
		if response == nil then
			response = http.response(404)
		else
			ok, response = pcall(http.response, response)
		end
	end
	if not ok then
		log('http: ' .. request.method .. ' ' .. request.full_path .. ' failed: ' .. tostring(response))
		response = http.response(500)
	end

	if connection.closed or connection.closing then
		return
	end
	local keep_alive = request.keep_alive and (response.headers.connection or ''):lower() ~= 'close'
	self:send(connection, response_bytes(response, request, keep_alive))
	connection.active = messaging.utc_time()
	if keep_alive then
		connection.busy = false
		self:next_request(connection)
	else
		self:close_connection(connection)
	end
end

-- a minimal client -----------------------------------------------------------------------------

-- make a plain HTTP request and return the response, with status, headers
-- (lower case names), body and response:json(). Blocks this thread until the
-- response arrives (so never call a server running in this same thread),
-- raising an error after timeout milliseconds (default 10000)
function http.fetch(method, url, body, headers, timeout)
	local host, port, target = url:match('^http://([^/:]+):?(%d*)(.*)$')
	if not host then
		error('http: fetch needs an http:// url, not ' .. tostring(url), 2)
	end
	port = port ~= '' and port or '80'
	target = target ~= '' and target or '/'
	body = body or ''

	local socket = messaging.socket('STREAM')
	socket:set_rcvtimeo(timeout or 10000)
	socket:connect('tcp://' .. host .. ':' .. port)
	local function fail(message)
		socket:close()
		error('http: ' .. method .. ' ' .. url .. ' ' .. message, 3)
	end

	-- the first message is the connection opening, with its id
	local frames = socket:recv_all()
	if not frames then
		fail('could not connect')
	end
	local id = frames[1]

	local lines = {
		method .. ' ' .. target .. ' HTTP/1.1',
		'host: ' .. host .. ':' .. port,
		'connection: close',
		'content-length: ' .. #body,
	}
	for name, value in pairs(headers or {}) do
		lines[#lines + 1] = name .. ': ' .. value
	end
	socket:send_all({ id, table.concat(lines, '\r\n') .. '\r\n\r\n' .. body })

	local buffer = ''
	local response, header_length
	while true do
		frames = socket:recv_all()
		if not frames then
			fail('timed out')
		end
		local data = frames[2]
		if data == '' then
			break -- closed by the server
		end
		buffer = buffer .. data
		response, header_length = parser.parse_response(buffer)
		if response == false then
			fail('received an invalid response')
		elseif response and response.status ~= 100 then
			local length = tonumber(response.headers['content-length'] or '')
			if length and #buffer >= header_length + length then
				break
			end
		elseif response then
			-- skip a 100 continue
			buffer = buffer:sub(header_length + 1)
		end
	end
	socket:send_all({ id, '' })
	socket:close()

	response, header_length = parser.parse_response(buffer)
	if not response then
		fail('received an incomplete response')
	end
	local result = response_class(response.status)
	result.headers = response.headers
	result.body = buffer:sub(header_length + 1)
	return result
end

return http
