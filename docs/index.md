# rascal documentation

rascal is a single executable Lua for building servers and tools. It is Lua 5.4 with SQLite, ZeroMQ, threads, JSON, MessagePack, filesystem access and HTTP parsing compiled in, plus an embedded library of Lua modules. Installing, building and the layout of the repository are covered in the [README](../README.md).

## Module reference

rascal's own Lua modules, embedded in the executable.

| Module | |
| --- | --- |
| [init](modules/init.md) | the script run in every Lua state: globals `log`, `loop` and prelude |
| [prelude](modules/prelude.md) | classes, lists and other small conveniences |
| [rascal.messaging](modules/rascal.messaging.md) | the shared ZeroMQ context, a loop per thread, coroutines on the loop |
| [rascal.threads](modules/rascal.threads.md) | starting threads from functions or source, with arguments |
| [rascal.services](modules/rascal.services.md) | serving and connecting to objects by name over ZeroMQ |
| [rascal.http](modules/rascal.http.md) | an HTTP server, handlers, requests and responses, and a minimal client |
| [rascal.database](modules/rascal.database.md) | simple SQLite access |
| [rascal.stowage](modules/rascal.stowage.md) | a key value store with a log and reverse index per key |
| [rascal.build](modules/rascal.build.md) | what the executable was built with |

## Technical reference

| | |
| --- | --- |
| [Architecture](technical/architecture.md) | how rascal is put together, and the choices behind it |
| [Building](technical/building.md) | the build, its options, static linking and platforms |
| [Adding dependencies](technical/adding-dependencies.md) | adding Lua modules, C libraries and patches |
| [Testing](technical/testing.md) | the test suite, and writing tests that don't depend on timing |
| [Performance](technical/performance.md) | load testing the HTTP server, and what to expect |

## Examples

Each example is a complete program in [`examples/`](../examples), and runs directly with `rascal`. With `--test`, the servers check themselves and exit, which is how the test suite runs them. Each page describes what the example does, and walks through its source.

| Example | |
| --- | --- |
| [work_queue](examples/work_queue.md) | a ROUTER queue that parks requests until there is a job, and sequential workers |
| [game_world](examples/game_world.md) | REQ/REP, PUSH/PULL and PUB/SUB together, with a server frame timer |
| [shared_cache](examples/shared_cache.md) | an ad hoc cache, each thread keeping its own copy, invalidated by PUB/SUB |
| [load_balancer](examples/load_balancer.md) | a ROUTER in front of DEALER connections to backends of different speeds |
| [http_server](examples/http_server.md) | routes in the server thread and in worker threads, static files, for load testing |
| [guestbook](examples/guestbook.md) | a small web app: entries in their own thread, live updates by long polling |

## Third party dependencies

Each is downloaded at a pinned version, checked against its sha256 and compiled in. Their licences are collected in `LICENSES.txt`, with each release and with `make licenses`. See [Third party dependencies](dependencies.md) for what each is used for.

| Dependency | require | Documentation |
| --- | --- | --- |
| Lua 5.4 | | [Lua 5.4 reference manual](https://www.lua.org/manual/5.4/) |
| SQLite | | [SQLite documentation](https://sqlite.org/docs.html) |
| lsqlite3 | `lsqlite3` | [lsqlite3 documentation](http://lua.sqlite.org/home/doc/tip/doc/lsqlite3.wiki) |
| ZeroMQ (libzmq) | | [ZeroMQ guide](https://zguide.zeromq.org/) and [API reference](https://libzmq.readthedocs.io/) |
| lzmq | `lzmq` | [lzmq documentation](https://moteus.github.io/lzmq/) |
| lua-llthreads2 | `llthreads2` | [lua-llthreads2](https://github.com/moteus/lua-llthreads2#readme) |
| lua-cjson | `cjson` | [lua-cjson manual](https://www.kyne.com.au/~mark/software/lua-cjson-manual.html), with [OpenResty's additions](https://github.com/openresty/lua-cjson#readme) |
| lua-cmsgpack | `cmsgpack` | [lua-cmsgpack](https://github.com/antirez/lua-cmsgpack#readme) |
| LuaFileSystem | `lfs` | [LuaFileSystem manual](https://lunarmodules.github.io/luafilesystem/manual.html) |
| picohttpparser | `rascal.http.parser` | [picohttpparser](https://github.com/h2o/picohttpparser#readme) |
