-- threads — run Lua code in new threads
--
-- local threads = require('rascal.threads')
-- local worker = threads.start([[
--     local name, count = ...
--     log(name .. ' counting to ' .. count)
-- ]], 'worker', 10)
-- worker:join()    -- optional, waits for the thread to complete
--
-- Thread code can also be a function, passed to the thread with string.dump.
-- It can use its arguments, globals and require, but not local variables
-- from outside it, which raises an error (pass them as arguments instead).
--
-- Each thread is a new Lua state, set up the same way as the main state
-- (including init), and every thread shares the process's ZeroMQ context so
-- inproc:// endpoints work between threads. Arguments are limited to what cmsgpack
-- can encode: nil, booleans, numbers, strings and tables of those. Threads
-- do not return values, results are sent back with messaging.
--
-- When a thread's code is complete its loop runs until it has no more work
-- (see messaging.complete), the same as the main thread after its script.
-- A thread that fails reports its error with log, and ends.

local llthreads = require('llthreads2')
local messaging = require('rascal.messaging')

local threads = {}

-- the code each new thread starts with, which then runs the thread's code
local bootstrap = [[return require('rascal.threads').run_thread(...)]]

-- an error with its stack trace, leaving out the frames of this module
local function traceback(err)
	local trace = debug.traceback(tostring(err), 2)
	return (trace:gsub('\n[^\n]*rascal/threads%.lua.*$', ''))
end

-- thread code as a string, from a string of Lua source or a function
function threads.code(code, level)
	level = (level or 1) + 1
	if type(code) == 'string' then
		return code
	elseif type(code) ~= 'function' then
		error('threads: thread code must be a function or a string of Lua source', level)
	end
	-- only _ENV, the globals, can be an upvalue, as it is the one upvalue set
	-- when the function is loaded in the new thread
	for i = 1, math.huge do
		local name = debug.getupvalue(code, i)
		if name == nil then
			break
		elseif name ~= '_ENV' then
			error("threads: the function refers to '" .. name .. "' from outside it, pass it as an argument instead", level)
		end
	end
	local ok, dumped = pcall(string.dump, code)
	if not ok then
		error('threads: unable to pass this function to a thread: ' .. dumped, level)
	end
	return dumped
end

-- load thread code from threads.code
function threads.load(code)
	local fn, err = load(code, '=thread', 'bt')
	if not fn then
		error(err, 0)
	end
	return fn
end

-- internal, run in a new thread
function threads.run_thread(code, packed_args, done_name, id)
	local ok, err = xpcall(function ()
		local fn, load_error = load(code, '=thread', 'bt')
		if not fn then
			error(load_error, 0)
		end
		fn(messaging.unpack(packed_args))
		messaging.complete()
	end, traceback)
	if not ok then
		local log = rawget(_G, 'log') or print
		log('thread failed: ' .. err)
	end
	-- tell the starting thread this one is done
	if id then
		local done = messaging.connect('PUSH', done_name)
		done:send(id)
		done:close()
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

local function start_thread(code, background, ...)
	code = threads.code(code, 3)
	local ok, packed_args = pcall(messaging.pack, ...)
	if not ok then
		error('threads: ' .. packed_args, 3)
	end
	local id = nil
	if not background then
		if not done_socket then
			done_name = string.format('rascal.threads.done.%p', running)
			done_socket = messaging.bind('PULL', done_name)
		end
		next_id = next_id + 1
		id = tostring(next_id)
	end
	local thread = llthreads.new(bootstrap, code, packed_args, done_name, id)
	-- detached, so that this thread is never blocked by it, even on errors
	local ok, err = thread:start(true, true)
	if not ok then
		error('threads: unable to start a thread: ' .. tostring(err), 3)
	end
	local handle = setmetatable({ thread = thread, id = id }, thread_handle)
	if not background then
		running[handle] = true
	end
	return handle
end

-- start a new thread running code, a function or a string of Lua source,
-- with the arguments given to it
function threads.start(code, ...)
	return start_thread(code, false, ...)
end

-- start a thread that this thread does not wait for when it completes,
-- for long running work that should end with the process, such as the
-- services registry. A background thread cannot be joined
function threads.start_background(code, ...)
	return start_thread(code, true, ...)
end

-- is the thread still running
function thread_handle:alive()
	receive_done()
	return not self.done and not self.joined
end

-- wait for the thread to complete
function thread_handle:join()
	if not self.id then
		error('threads: a background thread cannot be joined', 2)
	end
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
