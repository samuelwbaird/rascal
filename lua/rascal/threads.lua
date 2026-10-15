-- threads — run Lua code in new threads
--
-- local threads = require('rascal.threads')
-- local worker = threads.start([[
--     local name, count = ...
--     log(name .. ' counting to ' .. count)
-- ]], 'worker', 10)
-- worker:join()    -- optional, waits for the thread to complete
--
-- Each thread is a new Lua state, set up the same way as the main state
-- (including init), and shares the process's ZeroMQ context so inproc://
-- endpoints work between threads. Arguments are limited to what cmsgpack
-- can encode: nil, booleans, numbers, strings and tables of those. Threads
-- do not return values, results are sent back with messaging.
--
-- When a thread's code is complete its loop runs until it has no more work
-- (see messaging.complete), the same as the main thread after its script.
-- A thread that fails reports its error with log, and ends.

local llthreads = require('llthreads2')
local cmsgpack = require('cmsgpack')
local messaging = require('rascal.messaging')

local threads = {}

-- the code each new thread starts with, which then runs the thread's code
local bootstrap = [[return require('rascal.threads').run_thread(...)]]

-- an error with its stack trace, leaving out the frames of this module
local function traceback(err)
	local trace = debug.traceback(tostring(err), 2)
	return (trace:gsub('\n[^\n]*rascal/threads%.lua.*$', ''))
end

-- internal, run in a new thread
function threads.run_thread(code, context_pointer, packed_args, done_name, id)
	messaging.set_context(context_pointer)
	local ok, err = xpcall(function ()
		local args = cmsgpack.unpack(packed_args)
		local fn, load_error = load(code, '=thread', 't')
		if not fn then
			error(load_error, 0)
		end
		fn(table.unpack(args, 1, args.n))
		messaging.complete()
	end, traceback)
	if not ok then
		local log = rawget(_G, 'log') or print
		log('thread failed: ' .. err)
	end
	-- tell the starting thread this one is done
	local done = messaging.connect('PUSH', done_name)
	done:send(id)
	done:close()
end

-- check that values can be passed between threads
local function check_value(value, seen)
	local value_type = type(value)
	if value_type == 'table' then
		if seen[value] then
			error('threads: cannot pass a table that contains itself', 4)
		end
		seen[value] = true
		for k, v in pairs(value) do
			check_value(k, seen)
			check_value(v, seen)
		end
		seen[value] = nil
	elseif value_type ~= 'nil' and value_type ~= 'boolean' and value_type ~= 'number' and value_type ~= 'string' then
		error('threads: cannot pass a ' .. value_type .. ' to a thread', 4)
	end
end

-- threads started from this thread, until joined
local running = {}

-- each thread sends its id to the thread that started it when it is done,
-- as llthreads2 cannot reliably tell if a thread has ended before it is joined
local done_socket, done_name = nil, nil
local next_id = 0

local function receive_done()
	if not done_socket then
		return
	end
	while true do
		local id = done_socket:recv(messaging.zmq.DONTWAIT)
		if not id then
			break
		end
		for handle in pairs(running) do
			if handle.id == id then
				handle.done = true
			end
		end
	end
end

local thread_handle = {}
thread_handle.__index = thread_handle

-- start a new thread running code, a string of Lua source, with the
-- arguments available to it as ...
function threads.start(code, ...)
	if type(code) ~= 'string' then
		error('threads: thread code must be a string of Lua source', 2)
	end
	local args = table.pack(...)
	check_value(args, {})
	if not done_socket then
		done_name = string.format('rascal.threads.done.%p', running)
		done_socket = messaging.bind('PULL', done_name)
	end
	next_id = next_id + 1
	local id = tostring(next_id)
	local thread = llthreads.new(bootstrap, code, messaging.context():lightuserdata(), cmsgpack.pack(args), done_name, id)
	-- detached so that this thread never blocks on it, joinable to read its results
	local ok, err = thread:start(true, true)
	if not ok then
		error('threads: unable to start a thread: ' .. tostring(err), 2)
	end
	local handle = setmetatable({ thread = thread, id = id }, thread_handle)
	running[handle] = true
	return handle
end

-- is the thread still running
function thread_handle:alive()
	receive_done()
	return not self.done and not self.joined
end

-- wait for the thread to complete
function thread_handle:join()
	if not self.joined then
		self.thread:join()
		self.joined = true
		running[self] = nil
	end
end

-- keep this thread's loop running while threads it started are running
messaging.add_busy_check(function ()
	receive_done()
	local busy = false
	for handle in pairs(running) do
		if handle.done then
			handle:join()
		else
			busy = true
		end
	end
	return busy
end)

return threads
