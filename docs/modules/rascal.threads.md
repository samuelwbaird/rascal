# rascal.threads

Starting threads, each running Lua code in a new Lua state, with arguments. Source: [`lua/rascal/threads.lua`](../../lua/rascal/threads.lua).

```lua
local threads = require('rascal.threads')

threads.start(function (name, count)
	for i = 1, count do
		log(name, i)
	end
end, 'counter', 3)
```

## How threads work

Each thread is a new Lua state, set up the same way as the main state:
- the same compiled in and embedded modules
- [init](init.md), so `log`, `loop` and the prelude globals are there
- the same ZeroMQ context, so inproc endpoints work between threads

Threads share no Lua values. They communicate with [rascal.messaging](rascal.messaging.md) and [rascal.services](rascal.services.md), and threads don't return values: send results back through a socket or service instead.

When a thread's code is complete, its loop runs until it has no more work, exactly as for the main script. A thread serving a service keeps running until it closes the service. See [running to completion](rascal.messaging.md#running-to-completion).

A thread that starts other threads keeps running until they have finished. The main thread does the same, so a script that starts threads exits once they're done.

A thread whose code raises an error reports it with `log`, including a stack trace, and ends. The rest of the process carries on.

## Functions

### threads.start(code, ...)

Starts a thread running `code` with the arguments given, and returns a handle.

`code` is either:
- **a function**, which is the usual way. It's passed to the thread with `string.dump`.
  - **What it can use:** its arguments, globals and `require`. It can't use local variables from outside it, which would arrive as nil, so the function is checked first. Any outside local raises an error naming it, eg. `the function refers to 'services' from outside it, pass it as an argument instead`.
  - **Errors** report the function's real source file and line.
- **a string of Lua source**, with its arguments as `...`. Errors report the chunk as `thread`.

```lua
-- a function: require what it uses inside it
threads.start(function (name)
	local services = require('rascal.services')
	...
end, 'worker 1')

-- a string of source
threads.start([[
	local name = ...
	log('started', name)
]], 'worker 2')
```

Arguments are limited to what MessagePack can encode, see [values](rascal.messaging.md#values). A function, userdata or self-referencing table raises an error.

### threads.start_background(code, ...)

Starts a thread that the starting thread does not wait for, for long-running work that should simply end with the process. The services registry runs this way. A background thread can't be joined.

### threads.code(code)

Returns thread code as a string: the string itself, or a checked and dumped function. That string can be passed to another thread as an argument, and turned back into a function there with `threads.load`. So a thread can be given a function, eg. a class constructor, to create its own copy of:

```lua
local cache_client_code = threads.code(make_cache_client_class)

threads.start(function (cache_client_code)
	local cache_client = require('rascal.threads').load(cache_client_code)()
	...
end, cache_client_code)
```

### threads.load(code)

Loads code from `threads.code` as a function, raising an error if it can't be loaded.

## Thread handles

### handle:alive()

True while the thread is running.

### handle:join()

Waits for the thread to finish. Joining is optional: a thread's parent waits for it anyway, before completing. A background thread can't be joined.
