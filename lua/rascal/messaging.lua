-- messaging — ZeroMQ for rascal threads
--
-- local messaging = require('rascal.messaging')
-- local pull = messaging.bind('PULL', 'jobs')         -- inproc://jobs
-- messaging.loop():add_socket(pull, function (socket)
--     log('received', socket:recv())
-- end)
--
-- Every thread in the process shares one ZeroMQ context, so inproc:// works
-- between any of them. Each thread has its own loop for sockets and timers.
--
-- Endpoints are inproc names by default, network endpoints are used only
-- through the explicit bind_network and connect_network.
--
-- When a thread's code is complete (including the main script) its loop is
-- run, until it has no sockets or timers and no other work, see complete()

local zmq = require('lzmq')
local zloop = require('lzmq.loop')
local ztimer = require('lzmq.timer')
local cmsgpack = require('cmsgpack')

local messaging = {}

-- the lzmq module, eg. for socket options and constants
messaging.zmq = zmq

-- context and loop -------------------------------------------------------------------------

local context = nil
local loop = nil

-- the process wide context, shared by every thread. It is never terminated,
-- so threads are not interrupted as others end, and the process ends promptly
function messaging.context()
	if not context then
		context = zmq.init_ctx(require('rascal.context'))
	end
	return context
end

-- the loop for this thread, created on first use
function messaging.loop()
	if not loop then
		loop = zloop.new(messaging.context())
	end
	return loop
end

-- utc time in seconds, with fractions
function messaging.utc_time()
	return ztimer.absolute_time() / 1000
end

-- values -----------------------------------------------------------------------------------

-- values passed between threads are limited to what cmsgpack can encode:
-- nil, booleans, numbers, strings and tables of those

local function check_value(value, seen)
	local value_type = type(value)
	if value_type == 'table' then
		if seen[value] then
			error('messaging: cannot pass a table that contains itself', 0)
		end
		seen[value] = true
		for k, v in pairs(value) do
			check_value(k, seen)
			check_value(v, seen)
		end
		seen[value] = nil
	elseif value_type ~= 'nil' and value_type ~= 'boolean' and value_type ~= 'number' and value_type ~= 'string' then
		error('messaging: cannot pass a ' .. value_type, 0)
	end
end

-- pack any number of values into a string, raising an error for values
-- that cannot be passed between threads
function messaging.pack(...)
	local values = table.pack(...)
	check_value(values, {})
	return cmsgpack.pack(values)
end

-- the values from messaging.pack
function messaging.unpack(packed)
	local values = cmsgpack.unpack(packed)
	return table.unpack(values, 1, values.n)
end

-- sockets ----------------------------------------------------------------------------------

-- socket types can be given as names, eg. 'REQ', or as zmq constants
local function socket_type(type_or_name)
	if type(type_or_name) == 'string' then
		local value = zmq[type_or_name:upper()]
		if type(value) ~= 'number' then
			error('messaging: unknown socket type ' .. type_or_name, 4)
		end
		return value
	end
	return type_or_name
end

-- create a socket, optionally binding or connecting it to an endpoint
local function create(type_or_name, action, endpoint)
	local options = { socket_type(type_or_name) }
	if action then
		options[action] = endpoint
	end
	local socket, err = messaging.context():socket(options)
	if not socket then
		error('messaging: unable to ' .. (action or 'create socket') .. ' ' .. (endpoint or '') .. ': ' .. tostring(err), 3)
	end
	return socket
end

function messaging.socket(type_or_name)
	return create(type_or_name)
end

-- the inproc endpoint for a name
function messaging.inproc(name)
	return 'inproc://' .. name
end

function messaging.bind(type_or_name, name)
	return create(type_or_name, 'bind', messaging.inproc(name))
end

function messaging.connect(type_or_name, name)
	return create(type_or_name, 'connect', messaging.inproc(name))
end

-- a full endpoint, eg. 'tcp://*:8080'
function messaging.bind_network(type_or_name, endpoint)
	return create(type_or_name, 'bind', endpoint)
end

function messaging.connect_network(type_or_name, endpoint)
	return create(type_or_name, 'connect', endpoint)
end

-- running to completion --------------------------------------------------------------------

-- other work that keeps this thread running, eg. threads it has started
-- each check returns true while there is still work to wait for
local busy_checks = {}

function messaging.add_busy_check(fn)
	busy_checks[#busy_checks + 1] = fn
end

-- does this thread's loop have any sockets or active timers
-- (reads lzmq loop internals, which are pinned with the lzmq version)
local function loop_is_busy()
	if not loop then
		return false
	end
	if next(loop.private_.sockets) then
		return true
	end
	for _, event in ipairs(loop.private_.event_list.private_.events) do
		if event:started() then
			return true
		end
	end
	return false
end

local function is_busy()
	local busy = loop_is_busy()
	for _, check in ipairs(busy_checks) do
		-- every check is called, so each can tidy up as it goes
		if check() then
			busy = true
		end
	end
	return busy
end

-- run this thread's loop until it has no sockets, timers or other work, or
-- the loop is interrupted. This is called automatically when a thread's code,
-- or the main script, is complete. A socket stays in the loop until removed
-- with loop:remove_socket(socket)
function messaging.complete()
	while is_busy() do
		if loop then
			-- a short poll, so other work is checked regularly
			if not loop:poll(100) then
				return
			end
		else
			ztimer.sleep(100)
		end
	end
end

return messaging
