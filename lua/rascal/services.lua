-- services — serve and connect to objects over ZeroMQ, found by name
--
-- local services = require('rascal.services')
--
-- -- in one thread, serve an object's methods
-- local counter = { total = 0 }
-- function counter:add(amount) self.total = self.total + amount return self.total end
-- services.serve('counter', 'REP', { add = 'amount:number -> total:number' }, counter)
--
-- -- in any thread, connect by name (waiting until it is served) and call it
-- local counter = services.connect('counter')
-- print(counter:add(5))
--
-- :: socket types, given for the serving side
--   REP    request and reply, calls block until the result (or error) returns
--   ROUTER as REP for the caller, but each call runs as a coroutine (see
--          loop:schedule), so a method can yield, and calls in progress at the
--          same time are each replied to when they complete
--   PULL   push, calls are queued and return immediately
--   PUB    publish, calls go to every subscriber, see services.subscribe
--
-- :: api descriptions, one entry per method
--   { method_name = 'param:type, param:type -> result:type' }
--   types are documentation only for now, values are passed by position and
--   are limited to what cmsgpack can encode (see messaging.pack)
--
-- Services are served at inproc://<name> and listed in the registry, which
-- runs in a background thread. They can also be bound to network endpoints
-- with service:bind_network(endpoint).
--
-- Serving a service adds its socket to this thread's loop, so the thread
-- keeps running to answer it (see messaging.complete).

local messaging = require('rascal.messaging')
local threads = require('rascal.threads')

local log = rawget(_G, 'log') or print

local services = {}

local registry_name = 'rascal.registry'

-- the client socket type for each serving socket type
local client_socket_types = {
	REP = 'REQ',
	ROUTER = 'REQ',
	PULL = 'PUSH',
	PUB = 'SUB',
}

-- method names used by service and client objects themselves
local reserved_names = {
	close = true,
	bind_network = true,
}

-- api descriptions -------------------------------------------------------------------------

-- parse an api description into its methods, each with its parameter names
-- and result description
local function parse_api(api)
	if type(api) ~= 'table' or next(api) == nil then
		error('services: an api description is a table of method descriptions', 3)
	end
	local methods = {}
	for name, description in pairs(api) do
		if type(name) ~= 'string' or type(description) ~= 'string' then
			error('services: api methods must be described with strings, eg. method = \'value:string -> result:*\'', 3)
		end
		if reserved_names[name] then
			error('services: ' .. name .. ' cannot be used as a method name', 3)
		end
		local parameters_part, result = description:match('^(.-)%s*%->%s*(.-)%s*$')
		parameters_part = parameters_part or description
		local parameters = {}
		for parameter in parameters_part:gmatch('[^,]+') do
			local parameter_name = parameter:match('^%s*([^:%s]+)')
			if parameter_name then
				parameters[#parameters + 1] = parameter_name
			end
		end
		methods[name] = {
			name = name,
			description = description,
			parameters = parameters,
			result = result,
		}
	end
	return methods
end

-- an error with its stack trace, up to where the service called the method
local function traceback(err)
	local trace = debug.traceback(tostring(err), 2)
	trace = trace:gsub("\n%s*%[C%]: in function 'xpcall'.*$", '')
	return (trace:gsub('\n%s*%(%.%.%.tail calls%.%.%.%)$', ''))
end

-- call a method on the target with packed arguments
local function call_target(target, method, packed_args)
	local fn = target[method]
	if type(fn) ~= 'function' then
		error('no method ' .. method .. ' on the served object', 0)
	end
	return fn(target, messaging.unpack(packed_args))
end

-- requests ---------------------------------------------------------------------------------

-- send a request on a REQ socket and wait for the reply
local function request(socket, service_name, method, ...)
	local ok, packed = pcall(messaging.pack, ...)
	if not ok then
		error('services: ' .. service_name .. ':' .. method .. ' ' .. packed, 3)
	end
	local sent, send_error = socket:send_all({ method, packed })
	if not sent then
		error('services: unable to send to ' .. service_name .. ': ' .. tostring(send_error), 3)
	end
	local reply, receive_error = socket:recv()
	if not reply then
		error('services: no reply from ' .. service_name .. ': ' .. tostring(receive_error), 3)
	end
	local results = table.pack(messaging.unpack(reply))
	if not results[1] then
		error('services: ' .. service_name .. ':' .. method .. ' failed: ' .. tostring(results[2]), 3)
	end
	return table.unpack(results, 2, results.n)
end

-- the registry -----------------------------------------------------------------------------

local registry_socket = nil

-- make a request to the registry, starting it if needed. A registry thread is
-- started from each Lua state that uses services, the first to bind the
-- registry name runs it, and any others end straight away
local function registry_request(method, ...)
	if not registry_socket then
		threads.start_background([[require('rascal.services').run_registry()]])
		-- inproc allows connecting before the registry has bound
		registry_socket = messaging.connect('REQ', registry_name)
	end
	return request(registry_socket, 'registry', method, ...)
end

-- internal, run the registry in this thread, unless one is already running
function services.run_registry()
	local ok, socket = pcall(messaging.bind, 'ROUTER', registry_name)
	if not ok then
		return
	end

	local published = {}
	local waiting = {}

	local function reply(identity, ...)
		socket:send_all({ identity, '', messaging.pack(true, ...) })
	end

	local handlers = {}

	function handlers.publish(identity, details)
		if published[details.name] then
			socket:send_all({ identity, '', messaging.pack(false, 'a service named ' .. details.name .. ' is already published') })
			return
		end
		published[details.name] = details
		reply(identity, true)
		for _, waiting_identity in ipairs(waiting[details.name] or {}) do
			reply(waiting_identity, details)
		end
		waiting[details.name] = nil
	end

	function handlers.unpublish(identity, name)
		published[name] = nil
		reply(identity, true)
	end

	-- reply with the service details, once the service is published
	function handlers.wait(identity, name)
		if published[name] then
			reply(identity, published[name])
		else
			waiting[name] = waiting[name] or {}
			table.insert(waiting[name], identity)
		end
	end

	-- reply with the service details, or nil if not published
	function handlers.find(identity, name)
		reply(identity, published[name])
	end

	messaging.loop():add_socket(socket, function (socket)
		-- requests from REQ sockets arrive as identity, empty delimiter, method, arguments
		local frames = socket:recv_all()
		local identity, method, packed_args = frames[1], frames[3], frames[4]
		local handler = handlers[method]
		if not handler then
			socket:send_all({ identity, '', messaging.pack(false, 'the registry has no method ' .. tostring(method)) })
			return
		end
		handler(identity, messaging.unpack(packed_args))
	end)
end

-- wait until a service is published, returning its details
-- (name, endpoint, socket_type for clients, api)
function services.wait(name)
	return registry_request('wait', name)
end

-- the details of a service if it is published, or nil
function services.find(name)
	return registry_request('find', name)
end

-- serving ----------------------------------------------------------------------------------

local service_object = {}
service_object.__index = service_object

-- also listen on a network endpoint, eg. 'tcp://*:5555', returning the
-- endpoint bound (with any wildcard port resolved)
function service_object:bind_network(endpoint)
	local ok, err = self.socket:bind(endpoint)
	if not ok then
		error('services: unable to bind ' .. self.name .. ' to ' .. endpoint .. ': ' .. tostring(err), 2)
	end
	-- lzmq includes the terminating zero byte of the endpoint
	return (self.socket:get_last_endpoint():gsub('%z$', ''))
end

-- stop serving, and remove the service from the registry
-- (for REP and ROUTER services, closing waits until calls in progress have replied)
function service_object:close()
	if not self.socket then
		return
	end
	if self.calls_in_progress > 0 then
		self.close_when_complete = true
		return
	end
	registry_request('unpublish', self.name)
	messaging.loop():remove_socket(self.socket)
	self.socket:close()
	self.socket = nil
end

-- the reply to a request, from the results of xpcall
local function pack_reply(results)
	local ok, reply = pcall(messaging.pack, table.unpack(results, 1, results.n))
	if not ok then
		return messaging.pack(false, 'unable to return the result: ' .. reply)
	end
	return reply
end

-- serve the methods of target as a named service, with a socket type of
-- REP, ROUTER, PULL or PUB. A PUB service has no target, instead the returned
-- service object has a method for each api method that publishes the call
function services.serve(name, socket_type, api, target)
	local client_socket_type = client_socket_types[socket_type]
	if not client_socket_type then
		error('services: services can be served with REP, ROUTER, PULL or PUB sockets, not ' .. tostring(socket_type), 2)
	end
	local methods = parse_api(api)
	if socket_type ~= 'PUB' and type(target) ~= 'table' then
		error('services: a ' .. socket_type .. ' service needs a target object to call', 2)
	end

	local socket = messaging.bind(socket_type, name)
	local service = setmetatable({
		name = name,
		socket = socket,
		socket_type = socket_type,
		calls_in_progress = 0,
	}, service_object)

	local function call_complete()
		service.calls_in_progress = service.calls_in_progress - 1
		if service.close_when_complete and service.calls_in_progress == 0 then
			service:close()
		end
	end

	if socket_type == 'REP' then
		messaging.loop():add_socket(socket, function (socket)
			local frames = socket:recv_all()
			local method, packed_args = frames[1], frames[2]
			service.calls_in_progress = service.calls_in_progress + 1
			local results
			if not methods[method] then
				results = table.pack(false, 'no method ' .. tostring(method) .. ' in the api')
			else
				results = table.pack(xpcall(call_target, traceback, target, method, packed_args))
			end
			socket:send(pack_reply(results))
			call_complete()
		end)

	elseif socket_type == 'ROUTER' then
		messaging.loop():add_socket(socket, function (socket)
			-- requests from REQ sockets arrive as the routing envelope, an empty
			-- delimiter, then the method and arguments
			local frames = socket:recv_all()
			local envelope = {}
			while #frames > 0 and frames[1] ~= '' do
				envelope[#envelope + 1] = table.remove(frames, 1)
			end
			local method, packed_args = frames[2], frames[3]
			envelope[#envelope + 1] = ''

			service.calls_in_progress = service.calls_in_progress + 1
			messaging.loop():schedule(function ()
				local results
				if not methods[method] then
					results = table.pack(false, 'no method ' .. tostring(method) .. ' in the api')
				else
					results = table.pack(xpcall(call_target, traceback, target, method, packed_args))
				end
				envelope[#envelope + 1] = pack_reply(results)
				service.socket:send_all(envelope)
				call_complete()
			end)
		end)

	elseif socket_type == 'PULL' then
		messaging.loop():add_socket(socket, function (socket)
			local frames = socket:recv_all()
			local method, packed_args = frames[1], frames[2]
			if not methods[method] then
				log('service ' .. name .. ' received an unknown method ' .. tostring(method))
				return
			end
			local ok, err = xpcall(call_target, traceback, target, method, packed_args)
			if not ok then
				log('service ' .. name .. ':' .. method .. ' failed: ' .. err)
			end
		end)

	else
		-- PUB, a method on the service object for each api method
		for method in pairs(methods) do
			service[method] = function (self, ...)
				local ok, packed = pcall(messaging.pack, ...)
				if not ok then
					error('services: ' .. name .. ':' .. method .. ' ' .. packed, 2)
				end
				self.socket:send_all({ method, packed })
			end
		end
	end

	registry_request('publish', {
		name = name,
		endpoint = messaging.inproc(name),
		socket_type = client_socket_type,
		api = api,
	})
	return service
end

-- connecting -------------------------------------------------------------------------------

local client_object = {}
client_object.__index = client_object

function client_object:close()
	if self.socket then
		self.socket:close()
		self.socket = nil
	end
end

-- a DEALER connection, sending requests from coroutines, each parked until its reply
local dealer_object = setmetatable({}, { __index = client_object })
dealer_object.__index = dealer_object

-- closing resumes any calls still waiting, with an error
function dealer_object:close()
	if not self.socket then
		return
	end
	if self.in_loop then
		messaging.loop():remove_socket(self.socket)
	end
	self.socket:close()
	self.socket = nil
	local waiting = self.waiting
	self.waiting = {}
	for _, token in pairs(waiting) do
		messaging.loop():resume(token, nil)
	end
end

local function connect_dealer(name, details, methods)
	local loop = messaging.loop()
	local socket = messaging.connect_network('DEALER', details.endpoint)
	local client = setmetatable({
		name = name,
		socket = socket,
		api = details.api,
		waiting = {},		-- request id -> token
		outstanding = 0,
		next_id = 0,
		in_loop = false,
	}, dealer_object)

	-- replies arrive as the request id, an empty delimiter, then the reply
	local function receive(socket)
		local frames = socket:recv_all()
		local id, reply = frames[1], frames[3]
		local token = client.waiting[id]
		if not token then
			return
		end
		client.waiting[id] = nil
		client.outstanding = client.outstanding - 1
		-- only in the loop while waiting for replies, so an idle connection
		-- does not keep the thread running
		if client.outstanding == 0 then
			loop:remove_socket(socket)
			client.in_loop = false
		end
		loop:resume(token, reply)
	end

	for method in pairs(methods) do
		client[method] = function (self, ...)
			local _, is_main = coroutine.running()
			if is_main then
				error('services: calls on a DEALER connection to ' .. name .. ' must be made from within a coroutine, eg. in loop:schedule or a ROUTER method', 2)
			end
			if not self.socket then
				error('services: the DEALER connection to ' .. name .. ' is closed', 2)
			end
			local ok, packed = pcall(messaging.pack, ...)
			if not ok then
				error('services: ' .. name .. ':' .. method .. ' ' .. packed, 2)
			end
			self.next_id = self.next_id + 1
			local id = tostring(self.next_id)
			local token = {}
			self.waiting[id] = token
			self.outstanding = self.outstanding + 1
			if not self.in_loop then
				loop:add_socket(self.socket, receive)
				self.in_loop = true
			end
			-- the request id travels in the envelope, which REP and ROUTER services return
			self.socket:send_all({ id, '', method, packed })
			local reply = loop:suspend(token)
			if reply == nil then
				error('services: the DEALER connection to ' .. name .. ' was closed while waiting for ' .. method, 2)
			end
			local results = table.pack(messaging.unpack(reply))
			if not results[1] then
				error('services: ' .. name .. ':' .. method .. ' failed: ' .. tostring(results[2]), 2)
			end
			return table.unpack(results, 2, results.n)
		end
	end
	return client
end

-- connect to a REP, ROUTER or PULL service by name, waiting until it is
-- published, and return an object with a method for each api method
--
-- REP and ROUTER services are connected with REQ by default, where each call
-- blocks this thread until it returns. Connect with 'DEALER' to instead have
-- each call park only the coroutine making it (see loop:suspend), so other
-- coroutines, timers and sockets in this thread carry on meanwhile. Calls on
-- a DEALER connection must be made from within a coroutine. The socket type
-- has no effect on connections to PULL services.
function services.connect(name, socket_type)
	if socket_type ~= nil and socket_type ~= 'REQ' and socket_type ~= 'DEALER' then
		error('services: connect with REQ or DEALER, not ' .. tostring(socket_type), 2)
	end
	local details = services.wait(name)
	if details.socket_type == 'SUB' then
		error('services: ' .. name .. ' publishes, use services.subscribe', 2)
	end
	local methods = parse_api(details.api)
	if details.socket_type == 'REQ' and socket_type == 'DEALER' then
		return connect_dealer(name, details, methods)
	end

	local socket = messaging.connect_network(details.socket_type, details.endpoint)
	local client = setmetatable({ name = name, socket = socket, api = details.api }, client_object)

	for method in pairs(methods) do
		if details.socket_type == 'REQ' then
			client[method] = function (self, ...)
				return request(self.socket, name, method, ...)
			end
		else
			client[method] = function (self, ...)
				local ok, packed = pcall(messaging.pack, ...)
				if not ok then
					error('services: ' .. name .. ':' .. method .. ' ' .. packed, 2)
				end
				self.socket:send_all({ method, packed })
			end
		end
	end
	return client
end

-- subscribe to a PUB service by name, waiting until it is published. Each
-- published call is made on target, if target has that method. As with any
-- ZeroMQ subscription, calls published before the subscription connects are
-- not received
function services.subscribe(name, target)
	local details = services.wait(name)
	if details.socket_type ~= 'SUB' then
		error('services: ' .. name .. ' does not publish, use services.connect', 2)
	end
	local methods = parse_api(details.api)
	local socket = messaging.connect_network('SUB', details.endpoint)
	socket:subscribe('')
	messaging.loop():add_socket(socket, function (socket)
		local frames = socket:recv_all()
		local method, packed_args = frames[1], frames[2]
		if methods[method] and type(target[method]) == 'function' then
			local ok, err = xpcall(call_target, traceback, target, method, packed_args)
			if not ok then
				log('subscriber to ' .. name .. ':' .. method .. ' failed: ' .. err)
			end
		end
	end)
	local subscription = setmetatable({ name = name, socket = socket }, client_object)
	-- closing a subscription also removes it from the loop
	function subscription:close()
		if self.socket then
			messaging.loop():remove_socket(self.socket)
			self.socket:close()
			self.socket = nil
		end
	end
	return subscription
end

return services
