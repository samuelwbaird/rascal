# rascal

A single executable Lua for building servers. It is Lua 5.4 with SQLite, ZeroMQ, threads, JSON, MessagePack and filesystem access compiled in, plus an embedded library of Lua modules. There is nothing to install alongside it and no luarocks.

```
make          # builds build/<platform>/bin/rascal
make test     # runs the test suite and checks the binary's linkage
```

Requirements are `make`, a C and C++ compiler, `curl` and `tar`. It builds on macOS and Linux. Everything else is downloaded at pinned versions, checked against a sha256, and compiled from source.

## What's included

| require | from | version |
| --- | --- | --- |
| `lsqlite3` | [lsqlite3](http://lua.sqlite.org) with [SQLite](https://sqlite.org) (FTS5, R*Tree, JSON, math functions) | 0.9.6 / 3.54.0 |
| `lzmq`, `lzmq.loop`, `lzmq.poller`, `lzmq.threads`, `lzmq.timer` | [lzmq](https://github.com/zeromq/lzmq) with [libzmq](https://zeromq.org) | 0.4.4+ / 4.3.5 |
| `llthreads2`, `llthreads2.ex` | [lua-llthreads2](https://github.com/moteus/lua-llthreads2) | 0.1.6 |
| `cjson`, `cjson.safe` | [lua-cjson](https://github.com/openresty/lua-cjson) (OpenResty) | 2.1.0.19 |
| `cmsgpack`, `cmsgpack.safe` | [lua-cmsgpack](https://github.com/antirez/lua-cmsgpack) | 0.4.0 |
| `lfs` | [LuaFileSystem](https://github.com/lunarmodules/luafilesystem) | 1.9.0 |
| `prelude` | [prelude](https://github.com/samuelwbaird/prelude), embedded from `lua/` | |
| `rascal.database` | simple SQLite access over lsqlite3, embedded from `lua/rascal/database.lua` | |
| `rascal.stowage` | key value store with a log and reverse index per key, over `rascal.database` | |
| `rascal.messaging` | the shared ZeroMQ context, a loop per thread, inproc sockets by name | |
| `rascal.threads` | start threads from Lua source with arguments | |
| `rascal.services` | serve objects as named services (REQ/REP, ROUTER, DEALER, PUSH/PULL, PUB/SUB), including balanced across worker threads | |
| `rascal.http` | an HTTP server, with handlers in the server thread or in worker threads, and a minimal client | |
| `rascal.http.parser` | [picohttpparser](https://github.com/h2o/picohttpparser), parsing HTTP requests and responses | 1.4+ |
| `rascal.build` | build information, see below | |

`make info` lists the pinned versions.

## Using it

`rascal` is the standard Lua interpreter (`lua.c`), so `rascal script.lua`, `rascal -e`, `rascal -l` and the REPL all work as usual.

- **Init script**: every Lua state first runs the embedded `init` module, `lua/init.lua`. It currently makes prelude global (`require('prelude').global()`), so `class`, `list` and friends are available everywhere, defines a global `log(...)` that writes a timestamped line to stderr, and sets `loop` to this thread's messaging loop. It runs before `RASCAL_INIT`, `-e`, `-l` and the script, and before the global `arg` table exists. Start rascal with `--no-init` to skip it, in threads too. `--no-init` must come before the script name; after it, it is passed to the script like any other argument. It doesn't affect `RASCAL_INIT`, which is skipped with `-E` as in standard Lua. If the init script fails, rascal exits with the error. A failure inside a thread aborts the whole process.
- **Threads and messaging**:
  - **Starting threads:** `require('rascal.threads').start(code, ...)` runs a function, or a string of Lua source, in a new thread with the arguments given. A function is passed with `string.dump`, so it can use its arguments, globals and `require`, but not local variables from outside it. Arguments are limited to what cmsgpack can encode. Threads don't return values; results are sent back over ZeroMQ.
  - **Sockets:** every thread shares one ZeroMQ context. `rascal.messaging` names sockets as inproc endpoints by default, eg. `messaging.bind('PULL', 'jobs')`, with `bind_network` and `connect_network` for anything else.
  - **Running to completion:** once a thread's code, or the main script, is complete, its loop (`messaging.loop()`) runs until it has no sockets or timers and every thread it started has finished, then exits. A socket stays in the loop until it is removed with `loop:remove_socket`.
  - **Coroutines:** `loop:schedule(fn, ...)` runs a function as a coroutine on the loop, so timed sequences, repeating loops and waits read as straight-line code. Inside a coroutine:
    - `coroutine.yield(milliseconds)` waits that long, and `coroutine.yield()` waits one turn of the loop.
    - `coroutine.yield(condition)` waits until `condition()` returns true. It's checked whenever anything else has run in the thread, and at least every 100ms.
    - `loop:suspend(key)` parks the coroutine against a key (by default the coroutine itself) until `loop:resume(key, ...)`. Resuming wakes every coroutine parked against that key straight away, and `suspend` returns the values given to `resume`.
    - `loop:suspend` works in any coroutine, which the loop then adopts.
    - See `lua/rascal/messaging.lua` for the details.
  - **Failures:** a thread that fails reports its error with `log` and ends.
  - **Background threads:** `threads.start_background(code, ...)` starts a thread that its parent doesn't wait for, for long-running work that ends with the process.
  - **Services:** `rascal.services` serves an object's methods by name with `services.serve(name, 'REP' | 'ROUTER' | 'PULL' | 'PUB', api, target)`. Any thread can then call `services.connect(name)` or `services.subscribe(name, target)`, which wait until the service is served. The api is described with strings, eg. `{ add = 'amount:number -> total:number' }`, and values are passed by position.
    - A ROUTER service is called the same way as REP, but each call runs as a coroutine, so a method can yield (eg. `coroutine.yield(milliseconds)`). Calls from different callers can then be in progress at the same time, and each is replied to when it completes.
    - `services.connect(name, 'DEALER')` connects to a REP or ROUTER service so that each call parks only the coroutine making it, until its reply arrives (see `loop:suspend`). Other coroutines, timers and sockets in the thread carry on meanwhile, and one connection can have many calls in progress. Calls on a DEALER connection must be made from within a coroutine.
    - Errors in a REP or ROUTER method are raised in the caller.
    - `services.serve_balanced(name, worker_count, api, worker, ...)` serves a service whose calls are spread across worker threads, each answering the same api. Callers connect to it as to a REP service.
      - `worker` (a function or source) runs in each worker thread and returns the object to serve there.
      - Each call goes to the ready worker with the fewest calls in progress.
      - Each worker has its own state, so it suits apis that are stateless, or keep their state in other services.
    - Services are listed in a registry that runs in a background thread.
    - `service:bind_network(endpoint)` also makes a service reachable over the network.
  - **HTTP:** `rascal.http` serves http from one thread with a ZeroMQ STREAM socket, each request handled in its own coroutine.
    - **Handlers:** a handler takes `(request, context, ...)` and returns a response, or nil to let the next handler try. It can be a function, a list, an object with `:handle`, a fixed response, a matcher (`http.prefix`, `http.equal`, `http.match`), or remote: `http.workers(count, build)` runs handlers in balanced worker threads, and `http.service(name)` passes requests to a service.
    - **What crosses threads:** the request travels between threads as data. The `context` is per thread, for live objects.
    - **Client:** `http.fetch` is a minimal blocking client for tests and local services.
    - **Details:** see the comment at the top of `lua/rascal/http.lua`.
  - **Process exit:** the ZeroMQ context is shared by every thread and is never terminated, so a thread ending never interrupts sockets in other threads, and the process exits promptly.
- **Modules**: compiled in C modules are registered in `package.preload`. Embedded Lua modules are found by a searcher placed right after it, so they take priority over files on disk.
- **Threads**: every Lua state rascal creates gets the same modules, including each `llthreads2` / `lzmq.threads` thread. Thread code can `require` anything the main state can.
- **Environment**: rascal ignores `LUA_PATH`, `LUA_CPATH` and `LUA_INIT`, so it is isolated from any other Lua installation. Use `RASCAL_PATH`, `RASCAL_CPATH` and `RASCAL_INIT` instead. The default path is only `./?.lua;./?/init.lua`.
- **`RASCAL_PREFER_FILES=1`**: searches `package.path` before the embedded modules. This is handy while editing a module under `lua/` without rebuilding, eg. `RASCAL_PREFER_FILES=1 RASCAL_PATH='lua/?.lua;lua/?/init.lua' rascal app.lua`.
- **`require 'rascal.build'`** reports what the binary was built with:
  - `version`, `platform` and `lua_version`
  - `initialised`, false when started with `--no-init`
  - `dependencies` (name → version)
  - `c_modules` and `lua_modules`
  - `source(name)`, which returns an embedded module's source

## Layout

```
Makefile            build entry point and the generic per-dependency rules
config.mk           platform detection and build options
deps/<name>.mk      one file per dependency: version, url, sha256, sources, modules
patches/<name>/     patches applied to a dependency after unpacking, in order
lua/                Lua modules embedded in the executable (lua/a/b.lua -> require 'a.b')
lua/init.lua        the init script run in every Lua state
lua/rascal/         rascal's own modules (require 'rascal.<name>')
src/                rascal's own C: command line, opening Lua states, the embedded module searcher
tools/embed.lua     generates the C tables of modules from the build
scripts/            fetching, linkage checks, container builds
docker/             Linux build environments
tests/              test suite, run with make test (or rascal tests/run.lua [files])
  dependencies/     the third party libraries compiled in
  rascal/           rascal's own libraries
examples/           example programs, also run as tests (see Examples)
build/              all output (ignored): build/downloads and build/<platform>/
```

All output is under `build/<platform>/`, so macOS and Linux builds can share one checkout. They also share the download cache in `build/downloads/`. Within a platform directory:

- `src/` holds the unpacked sources.
- `bin/rascal` is the executable.
- `LICENSES.txt` is generated by `make licenses`.

## Examples

The `examples/` folder has complete programs showing patterns of threads, services and http. Each runs directly with rascal. The test suite runs each with `--test`: the servers then check themselves and exit, rather than serving until stopped.

| | |
| --- | --- |
| `work_queue.lua` | a ROUTER queue that parks requests until there is a job, and sequential workers |
| `game_world.lua` | REQ/REP, PUSH/PULL and PUB/SUB together, with a server frame timer |
| `shared_cache.lua` | an ad hoc cache, each thread keeping its own copy, invalidated by PUB/SUB |
| `load_balancer.lua` | a ROUTER in front of DEALER connections to backends of different speeds |
| `http_server.lua` | routes in the server thread and in worker threads, static files, slow routes, for load testing |
| `guestbook.lua` | a small web app: entries in their own thread, live updates by long polling |

```
rascal examples/http_server.lua 8080 4      # port, worker threads
rascal examples/guestbook.lua 8081          # then open http://127.0.0.1:8081/
```

### Load testing

`examples/http_server.lua` is set up for load testing, eg. with [wrk](https://github.com/wg/wrk):

```
wrk -t4 -c64 -d10s http://127.0.0.1:8080/hello            # handled in the server thread
wrk -t4 -c64 -d10s http://127.0.0.1:8080/workers/hello    # handled in worker threads
wrk -t4 -c256 -d10s http://127.0.0.1:8080/workers/slow    # each request waits 20ms in a worker
```

Measure on Linux. On macOS, each hand-off between ZeroMQ's I/O thread and rascal's threads is a slow kernel wake-up, which limits a single server to about 8,000 requests a second, however many connections there are. In a 2 CPU Linux container on the same machine, shared with wrk, the same server handled:
- about 60,000 requests a second in the server thread
- about 22,000 a second through worker threads
- 45,000 a second for static files

None of these runs had errors.

## Adding things

### A Lua module

Put it under `lua/` and run `make`. rascal's own modules live in `lua/rascal/`. Only `prelude` and `init` are at the top level. Don't add `lua/rascal/init.lua` unless it is meant to be `require 'rascal'` itself. The module name comes from the path: `lua/net/http.lua` becomes `require 'net.http'` and `lua/net/init.lua` becomes `require 'net'`. If it has its own licence, add `lua/LICENSE.<name>` and it will be included in `LICENSES.txt`.

Embedded modules should not depend on the `init` script having run, since rascal can be started with `--no-init`. `lua/rascal/database.lua` is the reference example. At the top of a module:

```lua
local prelude = require('prelude')             -- require dependencies as locals, not the init globals
local log = rawget(_G, 'log') or print         -- the init global log, or print without init
```

Other conventions:

- **Errors**: raise errors, with messages prefixed by the module name.
- **Per-state behaviour**: keep in mind that each thread is its own Lua state with its own copy of any module-level state, such as caches or open connections.

### A C library or Lua C module

Add `deps/<name>.mk`; it is picked up automatically. A typical one:

```make
# lua-foo — require 'foo'
DEPS += foo
foo_VERSION := 1.2.3
foo_HOME    := https://github.com/someone/lua-foo
foo_URL     := https://github.com/someone/lua-foo/archive/refs/tags/v$(foo_VERSION).tar.gz
foo_SHA256  := <sha256 of the archive>
foo_LICENSE := LICENSE

foo_SRCS     := src/foo.c src/foo_util.c         # relative to the unpacked archive
foo_CFLAGS   := -DFOO_SOME_OPTION
foo_INCLUDES := -I$(SRC)/foo/include             # only if other deps need its headers
foo_CMODULES := foo:luaopen_foo foo.bar:luaopen_foo_bar
foo_LUA      := foo.util:lua/foo/util.lua        # Lua files shipped with it
```

Leave `foo_SHA256` empty at first. The fetch will fail and print the actual hash to pin.

Optional variables:

- `_PRUNE`: paths to delete after unpacking, eg. bundled copies of libraries we already build.
- `_LICENSE_LINES`: a line range (eg. `1,27`) when the licence is inside a source file.
- `_LICENSE_NOTE`: text to use when there is no licence file.

Libraries with their own build system can set `<name>_LIB` to a static library and provide the rule to build it. See `deps/zeromq.mk`.

Each dependency's C sources are compiled with the Lua headers and every dependency's `_INCLUDES`.

**Gotcha:** a C module that creates new Lua states (as llthreads2 does) must open them with `rascal_openlibs` instead of `luaL_openlibs`. Otherwise its threads won't see the compiled in and embedded modules. Usually this needs no patch: add `-DluaL_openlibs=rascal_openlibs` to its `_CFLAGS`, as `deps/llthreads2.mk` does.

### A fix to a dependency

Put a `-p1` patch in `patches/<name>/`. Patches are applied in name order whenever the dependency is unpacked. Changing a patch or the `.mk` file re-unpacks that dependency and rebuilds.

## Linux and static linking

On macOS, all third party code is linked statically and the binary depends only on `libSystem` and `libc++`, as macOS doesn't allow fully static executables. `make test` checks this.

On Linux, the default (`STATIC=deps`) does the same against glibc, with libstdc++ and libgcc also linked statically. External C modules can still be loaded with `require`.

`make STATIC=full` builds a completely static executable. This is meant for musl, eg. Alpine, and the result runs on any Linux of the same architecture. Loading external C modules isn't possible in this mode.

Linux builds can be run from macOS with Docker:

```
scripts/docker-build.sh alpine    # fully static -> build/linux-<arch>-static/bin/rascal
scripts/docker-build.sh ubuntu    # glibc       -> build/linux-<arch>/bin/rascal
DOCKER_PLATFORM=linux/amd64 scripts/docker-build.sh alpine   # x86_64 from Apple silicon
```

## Other targets and options

| | |
| --- | --- |
| `make install` | install the stripped binary to `$PREFIX/bin` (default `/usr/local`) and licences to `$PREFIX/share/doc/rascal`; `DESTDIR` is supported for packaging |
| `make uninstall` | remove what `make install` installed, with the same `PREFIX` / `DESTDIR` |
| `make dist` | stripped binary and `LICENSES.txt` in `dist/rascal-<version>-<platform>/` |
| `make fetch` | download and unpack sources only, eg. before going offline |
| `make clean` | remove this platform's build directory, keeping downloads |
| `make distclean` | remove `build/` and `dist/` entirely |
| `DEBUG=1` | `-O0 -g`, and `make install` leaves the binary unstripped |
| `PREFIX=` | install location, eg. `make install PREFIX=$HOME/.local` |
| `CC=`, `CXX=`, `CFLAGS=` | the usual |

## Notes

- **Lua version**: Lua 5.4 is used rather than 5.5, as lzmq and llthreads2 predate 5.5. The version is a single setting in `deps/lua.mk`, along with its checksum.
- **lzmq**: there has been no lzmq release since 2016, so this uses the last upstream commit plus one patch (`patches/lzmq`).
- **No line editing in the REPL**: readline is left out to avoid an external dependency.
