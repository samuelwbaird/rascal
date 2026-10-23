# rascal.messaging

ZeroMQ for rascal threads: one context shared by every thread, sockets named as inproc endpoints, a loop per thread for sockets and timers, and coroutines on that loop. Source: [`lua/rascal/messaging.lua`](../../lua/rascal/messaging.lua).

```lua
local messaging = require('rascal.messaging')

local pull = messaging.bind('PULL', 'jobs')          -- inproc://jobs
loop:add_socket(pull, function (socket)
	log('received', (socket:recv()))
end)

loop:schedule(function ()
	coroutine.yield(1000)                             -- wait a second, without blocking the thread
	messaging.connect('PUSH', 'jobs'):send('hello')
end)
```

Most code uses [rascal.services](rascal.services.md), which is built on this module, rather than sockets directly. Sockets are [lzmq](https://moteus.github.io/lzmq/) sockets, so their full API is available, and the [ZeroMQ guide](https://zguide.zeromq.org/) describes the patterns.

## Context

### messaging.context()

The process-wide ZeroMQ context, as an lzmq context. Every thread shares it, which is what lets inproc endpoints work between threads.

It is created once, in C, and never terminated. So a thread or Lua state ending never blocks on, or interrupts, sockets in other threads, and the process exits promptly. See [Architecture](../technical/architecture.md#one-zeromq-context).

### messaging.zmq

The lzmq module, eg. for socket constants and options: `messaging.zmq.DONTWAIT`.

## Sockets

Socket types can be given as names, eg. `'PULL'` or `'pull'`, or as lzmq constants. An unknown type, or an endpoint that can't be bound or connected, raises an error.

| | |
| --- | --- |
| `messaging.socket(type)` | a new socket, not yet bound or connected |
| `messaging.bind(type, name)` | a socket bound to `inproc://<name>` |
| `messaging.connect(type, name)` | a socket connected to `inproc://<name>` |
| `messaging.bind_network(type, endpoint)` | a socket bound to a full endpoint, eg. `'tcp://*:5555'` |
| `messaging.connect_network(type, endpoint)` | a socket connected to a full endpoint |
| `messaging.inproc(name)` | the endpoint for a name: `'inproc://' .. name` |

Endpoints are inproc names by default. Network endpoints have their own explicit functions, so they stand out.

An inproc socket can connect before the other end binds; messages wait until it does. Two sockets can't bind the same name: the second raises an error that includes `EADDRINUSE`.

## Values

Values passed between threads, as thread arguments or service calls, are limited to what MessagePack can encode: nil, booleans, numbers, strings, and tables of those.

### messaging.pack(...)

Packs any number of values into a string. It raises an error for a function, userdata, coroutine or a table that contains itself, rather than letting them become nil silently.

### messaging.unpack(packed)

Returns the values from `messaging.pack`.

Two MessagePack quirks to know about:
- **Whole-number floats** come back as integers, eg. `3.0` as `3`.
- **Empty tables:** an empty table and an empty array can't be told apart.

## Time

### messaging.utc_time()

The current time in seconds, with fractions, eg. for measuring durations.

## The loop

### messaging.loop()

This thread's loop, an lzmq loop, created on first use. [init](init.md) also makes it the global `loop`.

The lzmq loop methods used most:

| | |
| --- | --- |
| `loop:add_socket(socket, fn)` | calls `fn(socket, events, loop)` whenever the socket has a message to receive |
| `loop:remove_socket(socket)` | stops watching a socket |
| `loop:add_once(milliseconds, fn)` | calls `fn(timer, loop)` once, after a delay |
| `loop:add_interval(milliseconds, fn)` | calls `fn(timer, loop)` repeatedly |
| `loop:sleep_ex(milliseconds)` | runs the loop for that long, eg. in a test, then returns |

`add_once` and `add_interval` return the timer, and `timer:reset()` stops it, so an interval can stop itself from its callback.

rascal adds three methods for coroutines, described below: `loop:schedule`, `loop:suspend` and `loop:resume`.

## Coroutines on the loop

### loop:schedule(fn, ...)

Runs `fn(...)` as a coroutine on the loop, straight away until it first yields, and returns the coroutine. Inside the coroutine, timed sequences, repeating loops and waits read as straight-line code:

```lua
loop:schedule(function ()
	for frame = 1, 30 do
		coroutine.yield(100)       -- every 100ms
		update(frame)
	end
end)
```

What a coroutine on the loop can yield:

| | |
| --- | --- |
| `coroutine.yield(milliseconds)` | resumes after that many milliseconds |
| `coroutine.yield()` | resumes on the next turn of the loop, letting other sockets and timers run |
| `coroutine.yield(condition)` | resumes once `condition()` returns true |

Anything else raises an error.

**Condition functions** need no polling interval. In a single-threaded loop, a condition can only become true when something else in the thread runs, or as time passes. So conditions are checked after anything else has run in the thread, and at least every 100ms while any are waiting.

```lua
coroutine.yield(function () return #queue > 0 end)
```

**Errors** in a scheduled coroutine are raised the same way as from any loop callback, with the coroutine's stack trace. Before its first yield, that's in the code that called `schedule`. After that, the thread reports the failure.

### loop:suspend(key)

Parks the current coroutine against a key until `loop:resume(key, ...)`, and returns the values given to that resume. The key is the coroutine itself if none is given, or any value, typically a table made fresh as a token.

```lua
-- park until resumed
local job = loop:suspend(token)

-- elsewhere in the same thread
loop:resume(token, job)
```

- **Outside a coroutine,** calling `suspend` raises an error.
- **Adopting coroutines:** it works in any coroutine, not only ones started by `schedule`. The loop then adopts the coroutine, so its later yields are handled as above.

### loop:resume(key, ...)

Wakes every coroutine parked against a key, and returns how many it woke.
- **Each one runs straight away**, inside the code calling `resume`, up to its next yield. So an error in a woken coroutine is raised in the code calling `resume`.
- **The key is cleared,** so each suspend is resumed at most once.
- **A resume is not remembered:** with nothing parked against the key, it does nothing. A later suspend won't see it.

To wait on shared state, check it again each time the coroutine is woken, as with a condition variable:

```lua
while queue:is_empty() do
	loop:suspend(queue)      -- woken whenever anything is added, then checks again
end
```

To give a wait a timeout, resume the same key from a timer:

```lua
local token = {}
local timeout = loop:add_once(25000, function () loop:resume(token) end)
local value = loop:suspend(token)    -- nil if it timed out
timeout:reset()
```

Parked coroutines are kept in weak tables. A coroutine parked against a key that nothing else refers to can be collected, along with its record.

## Running to completion

Once a thread's code, or the main script, is complete, its loop runs until the thread has no more work, then the thread ends. For the main thread, the process then exits.

Work that keeps a thread running:
- sockets in the loop (a socket stays until it is removed with `loop:remove_socket`)
- active timers
- coroutines waiting on time or on a condition
- threads it started that haven't finished (see [rascal.threads](rascal.threads.md))

A coroutine parked with `loop:suspend` does not keep its thread running. Only code in the same thread can resume it, and if nothing else is active in the thread, nothing can.

### messaging.complete()

Runs the loop until there is no more work, as above, or until the loop is interrupted. rascal calls this automatically after the main script, and after each thread's code, so it's rarely needed directly.

### messaging.add_busy_check(fn)

Adds a function that `complete` calls to ask whether there is other work to wait for, returning true while there is. [rascal.threads](rascal.threads.md) uses this to keep a thread running while its child threads are.
