# Architecture and design choices

rascal is for writing servers in Lua as a single executable, with nothing installed alongside it. This page describes how it's put together, and why it's done that way.

## One executable

rascal is the standard Lua interpreter, `lua.c`, linked with every dependency and an embedded library of Lua modules. So `rascal script.lua`, `-e`, `-l` and the REPL all work as in standard Lua, and a program is a Lua script plus the rascal executable.

Everything is compiled from source, at pinned versions, and linked statically, apart from the platform's system libraries. A program can't depend on something that happens to be installed on the build machine, and it runs the same on any machine with the same platform. On Linux, a fully static build runs on any distribution, or in an empty container. See [Building](building.md#static-linking).

There's no luarocks, and no package manager of rascal's own. A library becomes part of rascal by [adding it to the build](adding-dependencies.md), at a pinned version, so every program built with a given rascal has exactly the same libraries.

### Lua 5.4

rascal uses Lua 5.4 rather than 5.5, as lzmq and llthreads2 predate 5.5. The version is a single setting in [`deps/lua.mk`](../../deps/lua.mk), with its checksum. It's compiled with `LUA_COMPAT_5_3`.

### Modules in the executable

[`src/rascal.c`](../../src/rascal.c) has `rascal_openlibs`, which opens every Lua state rascal creates, in place of `luaL_openlibs`. It:
1. opens the standard libraries
2. registers the compiled in C modules in `package.preload`
3. adds a searcher for the embedded Lua modules, straight after the preload searcher, so they take priority over files on disk
4. runs the [init](../modules/init.md) module, unless rascal was started with `--no-init`

The embedded Lua modules are the files under [`lua/`](../../lua), and Lua files that dependencies ship. They're embedded as source, generated into C by [`tools/embed.lua`](../../tools/embed.lua) at build time. Each keeps its original path as its chunk name, so errors and stack traces point to the real file, eg. `lua/rascal/services.lua:120:`. `require('rascal.build').source(name)` returns a module's source.

`lua.c` is compiled with `-DluaL_openlibs=rascal_openlibs`, so the interpreter's main state is opened this way without changing its source. llthreads2 is compiled the same way, so each thread's state has the same modules too. Any C module that creates Lua states needs this, see [Adding dependencies](adding-dependencies.md#c-modules-that-create-lua-states).

### Isolated from other Lua installations

rascal reads `RASCAL_PATH`, `RASCAL_CPATH` and `RASCAL_INIT`, rather than `LUA_PATH`, `LUA_CPATH` and `LUA_INIT`. Its default path is only `./?.lua;./?/init.lua`. So a program behaves the same whatever other Lua is installed, and however it's configured.

`RASCAL_PREFER_FILES=1` searches `package.path` before the embedded modules. This is for working on rascal's own modules without rebuilding:

```bash
RASCAL_PREFER_FILES=1 RASCAL_PATH='lua/?.lua;lua/?/init.lua' rascal app.lua
```

### Command line

[`src/main.c`](../../src/main.c) removes rascal's own option, `--no-init`, from the command line, then hands the rest to `lua.c`, whose `main` is renamed `lua_main`. Options after the script name are always the script's own.

The REPL has no line editing, as readline is left out to avoid an external dependency.

## Running to completion

A server's script sets up sockets, services and timers, then reaches its end. Rather than exiting there, rascal runs the main thread's loop until it has nothing more to do.

This is a small patch to `lua.c` ([`patches/lua`](../../patches/lua)). Once the script, `-e`, `-l` and any REPL are done, it calls `rascal_push_complete`. If `rascal.messaging` has been loaded, this returns `messaging.complete`, which `lua.c` runs like the script, with the same error reporting and Ctrl-C handling. Threads do the same after their code.

A thread, or the process, has no more to do once it has:
- no sockets in its loop
- no active timers
- no coroutines waiting on time or a condition
- no threads it started still running

So a script that only computes something exits as usual, and a server runs until it closes its sockets. There's no explicit "run the loop" call, and no exit call is needed to end a program. See [rascal.messaging](../modules/rascal.messaging.md#running-to-completion).

## Threads own their state

rascal programs are a single process with several threads. Threads share nothing: each is a separate Lua state, communicating only by messages. This follows communicating sequential processes, and is how ZeroMQ is designed to be used.

The usual way to share something, such as a database, is for one thread to own it, and serve what other threads need as a [service](../modules/rascal.services.md). The owning thread handles one call at a time, so there are no locks, and no other thread ever sees its state part way through a change. Other threads can each keep a copy of what they read often, as in the [shared_cache](../examples/shared_cache.md) example.

So:
- **A single process.** rascal never spawns processes. One process is simpler to deploy, monitor and stop, and threads talk over inproc sockets, which are fast memory queues.
- **A thread per kind of work, rather than per request.** Many requests are handled in one thread, each in its own coroutine. More threads are used to own separate state, or to spread CPU-bound work, eg. with `services.serve_balanced`.
- **Network endpoints are explicit.** Sockets and services use inproc endpoints by name, unless a program asks for a network endpoint, eg. with `service:bind_network`.

### Threads

[rascal.threads](../modules/rascal.threads.md) starts threads with llthreads2. Thread code is usually a function, passed to the new state with `string.dump`. Only `_ENV` can be an upvalue, because it's the one set when the function is loaded again. So a function that uses an outside local is rejected with a clear error, rather than seeing nil. Thread code can also be a string of source, for code assembled at run time.

Arguments are packed with MessagePack. That limits them to plain values, the same as service calls.

A thread tells its parent when it's done with a message over inproc, as llthreads2 can't reliably tell if a detached thread has ended on every platform.

### One ZeroMQ context

The ZeroMQ context is created once, in C, the first time any thread asks for it, and is never terminated. Every thread shares it, which is what lets inproc sockets connect between threads.

Terminating a ZeroMQ context blocks until every socket in it is closed. If each Lua state owned or terminated the context, a thread ending could block, or interrupt sockets in other threads, and exiting the process could hang. As the context is never terminated, the process exits promptly, whatever sockets are still open.

### Coroutines on the loop

Each thread has one loop, an lzmq loop, polling its sockets and running its timers. rascal adds coroutines to it, so code that waits reads as straight-line code rather than callbacks:
- **Waiting:** a coroutine can wait for a time, the next turn of the loop, or a condition.
- **Parking:** it can be parked against a key until it's resumed.

A coroutine yields what it's waiting for, rather than calling a function on the loop for each kind of wait, so the code waiting doesn't need the loop:

```lua
coroutine.yield(100)                                  -- a time
coroutine.yield(function () return ready end)         -- a condition
local value = loop:suspend(key)                       -- until loop:resume(key, value)
```

Some choices in how this works:
- **Conditions aren't polled on an interval.** A condition can only change when something else in the thread runs, or as time passes. So conditions are checked after the loop has run anything, and at least every 100ms.
- **Resuming is immediate.** `loop:resume` runs the parked coroutines straight away, before it returns, rather than on a later turn of the loop. A resume isn't remembered: with nothing parked, it does nothing.
- **Parked coroutines can be adopted.** `loop:suspend` works in any coroutine, not only ones started by `loop:schedule`, so a library can suspend inside code it doesn't own, eg. an HTTP handler.
- **Parked coroutines don't keep a thread running.** Only code in the same thread can resume them, so if nothing else is active in the thread, nothing ever will.

## Services

[rascal.services](../modules/rascal.services.md) turns an object into a service, so calling another thread reads like calling a method:

```lua
local counter = services.connect('counter')
local total = counter:add(5)
```

Some choices in how this works:
- **Socket types are ZeroMQ's own.** Each service is one socket, of a ZeroMQ type that matches how it's called: REP, ROUTER, PULL or PUB. Clients connect with REQ, DEALER, PUSH or SUB. There's no broker in between.
- **API descriptions.** A service's methods are described with strings, eg. `'amount:number -> total:number'`, which document the API, and say which methods can be called. Values are passed by position, and limited to MessagePack. There's no type checking yet, but the description language leaves room for it.
- **A registry, so services are found by name.** A ROUTER service in a background thread holds each service's name, endpoint, socket type and API description. Connecting waits until a service is published, so threads can start in any order. Only services are registered, not every socket.
- **REQ by default, DEALER to wait without blocking.** REQ is the simplest client, and blocks only its own thread. A DEALER connection parks only the calling coroutine, so a ROUTER service or an HTTP handler can call other services and still handle other calls meanwhile.
- **No timeouts.** Calls between threads in one process don't get lost. A timeout, where it's needed, can be added with `loop:resume` from a timer.
- **No logging service.** Every thread writes to stderr directly with `log`, each line in one write.

`services.serve_balanced` spreads one service across worker threads. A ROUTER socket receives calls, and forwards each over DEALER to the ready worker with the fewest calls in progress. It doesn't use a REQ/REP chain, which can only give each worker one call at a time. So a worker whose methods yield can work on several calls at once.

## HTTP

[rascal.http](../modules/rascal.http.md) is a server in one thread, on that thread's loop. It reads connections with a ZeroMQ STREAM socket, so HTTP shares the loop with everything else in the thread, with no separate event library. Requests are parsed with picohttpparser.

Some choices in how this works:
- **A coroutine per request.** A handler can wait on anything a coroutine on the loop can, which makes long polling, slow upstream calls and timed responses straightforward.
- **Handlers are values.** A handler can be a function, a list, an object, a fixed response or a matcher wrapping another handler. Composing these covers routing and middleware, with no framework.
- **The request travels as data; the context stays in its thread.** A request can be handled in another thread, as a service, so it's limited to plain values. The context is per thread, for live objects such as a database connection or a session, and is never passed between threads.
- **Workers are a balanced service.** `http.workers` is `services.serve_balanced` with a handler API, so slow handlers move to other threads with one change to the routing.
- **Sending never blocks.** The STREAM socket's send timeout is zero, so a client that stops reading is disconnected, rather than stalling every other connection in the thread.
- **Plain HTTP/1.1.** There's no TLS, HTTP/2 or chunked request bodies. A server is expected to sit behind a proxy that terminates TLS.

Some features are deliberately left for later, or for programs to add themselves:
- **Compression** is better done by the proxy in front.
- **Lua as a response format,** eg. `application/lua`, would mean running code received from a client. MessagePack and JSON are used instead.

## Library modules and examples

rascal's library modules provide the parts that every program needs: threads, messaging, services, HTTP, databases. Patterns built from them, such as a cache, a work queue or a load balancer, stay as [examples](../index.md#examples) rather than becoming configurable library modules. Each program can then copy and adapt the pattern, and the library stays small.

Library modules work without the [init](../modules/init.md) globals, so they also work under `--no-init`, and raise errors prefixed with their module name. See [Adding dependencies](adding-dependencies.md#conventions-for-embedded-modules).

## Dependencies

Each dependency was chosen to be small, portable C that builds without its own build system, apart from libzmq. See [Third party dependencies](../dependencies.md).

- **lzmq** has had no release since 2016. rascal uses its last upstream commit, plus one patch adding a missing include ([`patches/lzmq`](../../patches/lzmq)).
- **libzmq** is built with its own configure script, with every optional feature off. Anything it detected on the build machine would otherwise become a dynamic dependency of the executable.
- **SQLite** is compiled with FTS5, R*Tree, GEOPOLY, math functions and other options, see [dependencies](../dependencies.md#sqlite).
- **Mbed TLS** is compiled with only its digest, HMAC and base64 sources, by a configuration of rascal's own, for [rascal.crypto](../modules/rascal.crypto.md). It's the library rascal would also use for TLS, if outgoing HTTPS is added later. Secure random values are read from `/dev/urandom` rather than through Mbed TLS.
