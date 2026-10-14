-- lzmq with the compiled in libzmq, including sockets shared between threads
local zmq = require('lzmq')
local zthreads = require('lzmq.threads')
local ztimer = require('lzmq.timer')
local rascal = require('rascal')

local version = zmq.version()
expect_equal(table.concat(version, '.'), rascal.dependencies.zeromq)

local ctx = zmq.context()

-- in process messaging with a thread sharing the context
local pair = assert(ctx:socket({ zmq.PAIR, bind = 'inproc://rascal-test' }))
local thread = zthreads.run(ctx, [[
	local zmq = require('lzmq')
	local zthreads = require('lzmq.threads')
	local prelude = require('prelude')
	local ctx = zthreads.get_parent_ctx()
	local pair = assert(ctx:socket({ zmq.PAIR, connect = 'inproc://rascal-test' }))
	local message = assert(pair:recv())
	assert(pair:send(message:upper()))
	pair:close()
]])
assert(thread:start())
assert(pair:send('hello'))
pair:set_rcvtimeo(5000)
expect_equal(pair:recv(), 'HELLO')
assert(thread:join())
pair:close()

-- request and reply over tcp on loopback
local rep = assert(ctx:socket({ zmq.REP, bind = 'tcp://127.0.0.1:*' }))
local endpoint = rep:get_last_endpoint()
local server = zthreads.run(ctx, [[
	local zmq = require('lzmq')
	local cjson = require('cjson')
	local ctx = require('lzmq.threads').get_parent_ctx()
	local req = assert(ctx:socket({ zmq.REQ, connect = ... }))
	req:set_rcvtimeo(5000)
	assert(req:send(cjson.encode({ question = 6 * 7 })))
	local reply = assert(req:recv())
	req:close()
	assert(cjson.decode(reply).answer == 42)
]], endpoint)
assert(server:start())
rep:set_rcvtimeo(5000)
local request = require('cjson').decode((assert(rep:recv())))
assert(rep:send(require('cjson').encode({ answer = request.question })))
assert(server:join())
rep:close()

-- timers
local timer = ztimer.monotonic(10)
timer:start()
assert(timer:rest() <= 10)
assert(ztimer.absolute_time() > 0)

ctx:term()
