-- rascal.messaging: context, sockets, loop and running to completion
local messaging = require('rascal.messaging')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

expect_equal(messaging.context(), messaging.context(), 'one context')
expect_equal(messaging.loop(), messaging.loop(), 'one loop per thread')
assert(math.abs(messaging.utc_time() - os.time()) < 2)

-- inproc by name, socket types by name or constant
local server = messaging.bind('PAIR', 'test_messaging')
local client = messaging.connect(messaging.zmq.PAIR, 'test_messaging')
client:send('hello')
expect_equal(server:recv(), 'hello')
server:close()
client:close()
expect_error('unknown socket type', messaging.socket, 'NOT_A_TYPE')
expect_error('unable to bind', messaging.bind_network, 'PAIR', 'not an endpoint')

-- network endpoints are explicit
local rep = messaging.bind_network('REP', 'tcp://127.0.0.1:*')
local req = messaging.connect_network('REQ', rep:get_last_endpoint())
req:send('ping')
expect_equal(rep:recv(), 'ping')
rep:send('pong')
expect_equal(req:recv(), 'pong')
rep:close()
req:close()

-- the loop runs sockets and timers
local pull = messaging.bind('PULL', 'test_messaging_loop')
local push = messaging.connect('PUSH', 'test_messaging_loop')
local received, fired = nil, false
messaging.loop():add_socket(pull, function (socket) received = socket:recv() end)
messaging.loop():add_once(10, function () fired = true end)
push:send('via loop')
assert(wait_until(function () return received ~= nil and fired end), 'the socket and timer were handled')
expect_equal(received, 'via loop')
messaging.loop():remove_socket(pull)
pull:close()
push:close()

-- after the script, the loop runs until it has no sockets or timers
expect_equal(run_rascal_script([[
	local messaging = require('rascal.messaging')
	local count, timer = 0, nil
	timer = messaging.loop():add_interval(20, function ()
		count = count + 1
		print('tick ' .. count)
		if count == 3 then
			timer:reset()
		end
	end)
	print('script done')
]]), 'script done\ntick 1\ntick 2\ntick 3')

-- a socket keeps the loop running until it is removed
expect_equal(run_rascal_script([[
	local messaging = require('rascal.messaging')
	local pull = messaging.bind('PULL', 'work')
	messaging.loop():add_socket(pull, function (socket)
		print((socket:recv()))
		messaging.loop():remove_socket(socket)
	end)
	messaging.loop():add_once(50, function ()
		messaging.connect('PUSH', 'work'):send('received after the script')
	end)
]]), 'received after the script')

-- scripts that never load messaging are unaffected
expect_equal(run_rascal_script([[print('plain')]]), 'plain')

-- loop:schedule runs a function as a coroutine, which waits by yielding milliseconds
expect_equal(loop, messaging.loop(), 'init sets loop as a global')
local steps = {}
loop:schedule(function (label)
	steps[#steps + 1] = label .. ' started'
	coroutine.yield(20)
	steps[#steps + 1] = label .. ' after 20ms'
	coroutine.yield()
	steps[#steps + 1] = label .. ' after a turn of the loop'
end, 'first')
expect_equal(table.concat(steps, ', '), 'first started', 'runs straight away, until it first yields')
wait_until(function () return #steps == 3 end)
expect_equal(table.concat(steps, ', '), 'first started, first after 20ms, first after a turn of the loop')

-- errors are raised with the coroutine's stack trace
expect_error('scheduled failure', loop.schedule, loop, function () error('scheduled failure') end)
expect_error('can yield a number of milliseconds', loop.schedule, loop, function () coroutine.yield('soon') end)

-- coroutines interleave, and keep the thread running until they are complete
-- (each runs straight away until it yields, then continues after the script,
-- the order between them after that depends on timing, so is not checked)
local interleaved = run_rascal_script([[
	for _, name in ipairs({ 'a', 'b' }) do
		loop:schedule(function ()
			for i = 1, 3 do
				print(name .. i)
				coroutine.yield(10)
			end
		end)
	end
	print('script done')
]])
expect_equal(interleaved:sub(1, #'a1\nb1\nscript done\n'), 'a1\nb1\nscript done\n')
local function in_order(text, ...)
	local position = 0
	for _, line in ipairs({ ... }) do
		local found = text:find(line, position + 1, true)
		if not found then
			return false
		end
		position = found
	end
	return true
end
assert(in_order(interleaved, 'a1', 'a2', 'a3') and in_order(interleaved, 'b1', 'b2', 'b3'), interleaved)

-- loop:suspend parks a coroutine, by default against itself, until loop:resume
local events = {}
local parked_co = loop:schedule(function ()
	local value = loop:suspend()
	events[#events + 1] = 'resumed with ' .. value
	coroutine.yield()
	events[#events + 1] = 'after a turn of the loop'
end)
expect_equal(#events, 0, 'parked')
expect_equal(loop:resume(parked_co, 'first'), 1)
expect_equal(table.concat(events, ', '), 'resumed with first', 'resumed straight away, up to its next yield')
expect_equal(loop:resume(parked_co, 'again'), 0, 'each suspend is resumed only once')
wait_until(function () return #events == 2 end)
expect_equal(table.concat(events, ', '), 'resumed with first, after a turn of the loop')

-- every coroutine parked against a key is woken, and cleared from it
local token = {}
local woken = {}
for _, name in ipairs({ 'a', 'b' }) do
	loop:schedule(function ()
		local x, y = loop:suspend(token)
		woken[#woken + 1] = name .. x .. y
	end)
end
expect_equal(loop:resume(token, 1, 2), 2)
expect_equal(table.concat(woken, ', '), 'a12, b12')
expect_equal(loop:resume(token), 0)
expect_equal(loop:resume('nothing parked here'), 0, 'a resume with nothing parked does nothing')

-- waiting on shared state: check again each time the coroutine is woken
local queue = { items = {} }
local taken = {}
for _, name in ipairs({ 'first', 'second' }) do
	loop:schedule(function ()
		while #queue.items == 0 do
			loop:suspend(queue)
		end
		taken[#taken + 1] = name .. ' took ' .. table.remove(queue.items, 1)
	end)
end
queue.items[1] = 'job'
loop:resume(queue)
expect_equal(table.concat(taken, ', '), 'first took job', 'the second checks again, and parks again')
queue.items[1] = 'another job'
loop:resume(queue)
expect_equal(table.concat(taken, ', '), 'first took job, second took another job')

-- suspend is only possible from within a coroutine
expect_error('must be called from within a coroutine', loop.suspend, loop)
expect_error('needs the key', loop.resume, loop)

-- any coroutine can be suspended, and is then adopted by the loop
local adopted_steps = {}
local outside = coroutine.create(function ()
	adopted_steps[#adopted_steps + 1] = loop:suspend('adopt')
	coroutine.yield(10)
	adopted_steps[#adopted_steps + 1] = 'after 10ms on the loop'
end)
assert(coroutine.resume(outside))
expect_equal(loop:resume('adopt', 'adopted'), 1)
wait_until(function () return #adopted_steps == 2 end)
expect_equal(table.concat(adopted_steps, ', '), 'adopted, after 10ms on the loop')

-- a record left by resuming a coroutine some other way is replaced on its next suspend
local moved = coroutine.create(function ()
	loop:suspend('first key')
	return loop:suspend('second key')
end)
assert(coroutine.resume(moved))
assert(coroutine.resume(moved)) -- resumed directly, not through the loop
expect_equal(loop:resume('first key'), 0, 'no longer parked against the first key')
expect_equal(loop:resume('second key'), 1)

-- yielding a condition resumes once it is true, checked whenever anything else has run
local flag = false
local condition_met = false
loop:schedule(function ()
	coroutine.yield(function () return flag end)
	condition_met = true
end)
loop:sleep_ex(20)
expect_equal(condition_met, false, 'not met while the flag is false')
loop:add_once(1, function () flag = true end)
assert(wait_until(function () return condition_met end), 'met once a timer sets the flag')

-- a condition keeps the thread running, a parked coroutine does not
expect_equal(run_rascal_script([[
	local messaging = require('rascal.messaging')
	local finish = messaging.utc_time() + 0.2
	loop:schedule(function ()
		coroutine.yield(function () return messaging.utc_time() >= finish end)
		print('condition met')
	end)
	loop:schedule(function ()
		loop:suspend()
		print('never resumed')
	end)
	print('script done')
]]), 'script done\ncondition met')

-- a coroutine parked against a key that nothing else refers to can be collected
local reference = setmetatable({}, { __mode = 'v' })
reference[1] = loop:schedule(function () loop:suspend({}) end)
reference[2] = loop:schedule(function () loop:suspend() end)
collectgarbage()
collectgarbage()
expect_equal(reference[1], nil, 'parked against a dropped token')
expect_equal(reference[2], nil, 'parked against itself')
