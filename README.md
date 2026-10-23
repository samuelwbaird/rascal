# rascal

A single executable Lua for building servers. It is Lua 5.4 with SQLite, ZeroMQ, threads, JSON, MessagePack and filesystem access compiled in, plus an embedded library of Lua modules. There is nothing to install alongside it and no luarocks.

```
make          # builds build/<platform>/bin/rascal
make test     # runs the test suite and checks the binary's linkage
```

Requirements are `make`, a C and C++ compiler, `curl` and `tar`. It builds on macOS and Linux. Everything else is downloaded at pinned versions, checked against a sha256, and compiled from source.

## Installing

```bash
curl -fsSL https://raw.githubusercontent.com/samuelwbaird/rascal/main/install.sh | sh
```

`install.sh` installs the latest release for macOS (arm64, x86_64) or Linux (x86_64, aarch64). The Linux executables are fully static, so they run on any distribution, or in any container. It installs to `~/.local/bin`, or `/usr/local/bin` as root.
- **Settings:** `PREFIX=...` to install elsewhere, and `RASCAL_VERSION=0.1.0` for a particular release.
- **Without a prebuilt executable,** or with `RASCAL_FROM_SOURCE=1`, it builds from source. That needs make, a C and C++ compiler and tar. Each release includes every dependency's download, so a source build only needs GitHub.

With Homebrew, on macOS or Linux:

```bash
brew install samuelwbaird/tap/rascal
```

### In a container

The Linux executables are fully static, so the simplest way into any image is to download one in a build stage and copy it across. This works with any base image, including `FROM scratch`:

```dockerfile
# download rascal for this image's architecture, and check it against the release's checksums
FROM alpine:3.22 AS rascal
ARG RASCAL_VERSION=0.1.0
ARG TARGETARCH
RUN apk add --no-cache curl \
 && case "$TARGETARCH" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; *) exit 1 ;; esac \
 && file=rascal-$RASCAL_VERSION-linux-$arch-static.tar.gz \
 && release=https://github.com/samuelwbaird/rascal/releases/download/v$RASCAL_VERSION \
 && curl -fsSLO "$release/$file" -O "$release/SHA256SUMS" \
 && grep " $file\$" SHA256SUMS | sha256sum -c - \
 && tar -xzf "$file" \
 && mv rascal-$RASCAL_VERSION-linux-$arch-static/rascal /usr/local/bin/rascal

# then copy it into any image, as it needs nothing from the system
FROM debian:12-slim
COPY --from=rascal /usr/local/bin/rascal /usr/local/bin/rascal
```

In an image that already has `curl`, the install script works too:

```dockerfile
RUN curl -fsSL https://raw.githubusercontent.com/samuelwbaird/rascal/main/install.sh | RASCAL_VERSION=0.1.0 sh
```

### Downloads

Releases can also be downloaded from https://github.com/samuelwbaird/rascal/releases. Each has:
- the executable and its licences for each platform
- `rascal-<version>-dependencies.tar`, for building from source offline: extract it into `build/`, then `make`
- `SHA256SUMS`

To build from a clone instead, use `make && make install`. That needs `xcode-select --install` on macOS, or eg. `apt-get install build-essential curl` or `apk add build-base linux-headers curl` on Linux.

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
| `rascal.threads` | start threads from functions or Lua source, with arguments | |
| `rascal.services` | serve objects as named services (REQ/REP, ROUTER, DEALER, PUSH/PULL, PUB/SUB), including balanced across worker threads | |
| `rascal.http` | an HTTP server, with handlers in the server thread or in worker threads, and a minimal client | |
| `rascal.http.parser` | [picohttpparser](https://github.com/h2o/picohttpparser), parsing HTTP requests and responses | 1.4+ |
| `rascal.build` | build information, see [rascal.build](docs/modules/rascal.build.md) | |

`make info` lists the pinned versions.

## Using it

`rascal` is the standard Lua interpreter, so `rascal script.lua`, `rascal -e`, `rascal -l` and the REPL all work as usual. Every library above is available with `require`, with nothing on disk.

```lua
-- hello.lua: rascal hello.lua, then open http://127.0.0.1:8080/
local http = require('rascal.http')

local server = http.server()
server:equal('/', function (request)
	return http.text('hello ' .. (request.vars.name or 'world'))
end)
server:listen('tcp://*:8080')
```

A few things differ from standard Lua:
- **Init:** every Lua state first runs the embedded [`init`](docs/modules/init.md) module, which makes [prelude](docs/modules/prelude.md) global, and adds a `log` function and the thread's messaging `loop`. Start rascal with `--no-init` to skip it.
- **Running to completion:** once the script is complete, its loop runs until it has no sockets, timers or threads left, so a server keeps serving without any explicit "run" call. See [running to completion](docs/modules/rascal.messaging.md#running-to-completion).
- **Environment:** rascal ignores `LUA_PATH`, `LUA_CPATH` and `LUA_INIT`, so it's isolated from any other Lua installation. Use `RASCAL_PATH`, `RASCAL_CPATH` and `RASCAL_INIT` instead. The default path is only `./?.lua;./?/init.lua`.
- **Embedded modules first:** embedded modules take priority over files on disk. `RASCAL_PREFER_FILES=1` searches `package.path` first, eg. to work on a module under `lua/` without rebuilding.

## Documentation

The [documentation](docs/index.md) has:
- **[Module reference](docs/index.md#module-reference):** the API of each of rascal's Lua modules
- **[Technical reference](docs/index.md#technical-reference):** [architecture and design choices](docs/technical/architecture.md), [building](docs/technical/building.md), [adding dependencies](docs/technical/adding-dependencies.md), [testing](docs/technical/testing.md) and [performance](docs/technical/performance.md)
- **[Examples](docs/index.md#examples):** a guide to each example, chunk by chunk
- **[Third party dependencies](docs/dependencies.md):** what each is used for, with links to its documentation

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
docs/               documentation, see docs/index.md
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

The `examples/` folder has complete programs showing patterns of threads, services and http. Each runs directly with rascal, and each has a [guide](docs/index.md#examples) that walks through its source.

| | |
| --- | --- |
| [`work_queue.lua`](docs/examples/work_queue.md) | a ROUTER queue that parks requests until there is a job, and sequential workers |
| [`game_world.lua`](docs/examples/game_world.md) | REQ/REP, PUSH/PULL and PUB/SUB together, with a server frame timer |
| [`shared_cache.lua`](docs/examples/shared_cache.md) | an ad hoc cache, each thread keeping its own copy, invalidated by PUB/SUB |
| [`load_balancer.lua`](docs/examples/load_balancer.md) | a ROUTER in front of DEALER connections to backends of different speeds |
| [`http_server.lua`](docs/examples/http_server.md) | routes in the server thread and in worker threads, static files, slow routes, for load testing |
| [`guestbook.lua`](docs/examples/guestbook.md) | a small web app: entries in their own thread, live updates by long polling |

```
rascal examples/http_server.lua 8080 4      # port, worker threads
rascal examples/guestbook.lua 8081          # then open http://127.0.0.1:8081/
```

The test suite runs each example too, with `--test`: the servers then check themselves and exit, rather than serving until stopped. See [Performance](docs/technical/performance.md) for load testing `http_server.lua`.

## Adding things

- **A Lua module:** put it under `lua/` and run `make`. `lua/net/http.lua` becomes `require('net.http')`.
- **A C library or Lua C module:** add `deps/<name>.mk`, which is picked up automatically.
- **A fix to a dependency:** put a `-p1` patch in `patches/<name>/`.

See [Adding dependencies](docs/technical/adding-dependencies.md) for the details, and the conventions for embedded modules.

## Linux and static linking

On macOS, all third party code is linked statically, and the executable depends only on `libSystem` and `libc++`. On Linux, `make` does the same against glibc, and `make STATIC=full` builds a completely static executable, for musl, eg. Alpine. Linux builds can be run from macOS with Docker:

```
scripts/docker-build.sh alpine    # fully static -> build/linux-<arch>-static/bin/rascal
scripts/docker-build.sh ubuntu    # glibc       -> build/linux-<arch>/bin/rascal
```

See [Building](docs/technical/building.md) for how the build works, and its options.

## Other targets and options

| | |
| --- | --- |
| `make install` | install the stripped binary to `$PREFIX/bin` (default `/usr/local`) and licences to `$PREFIX/share/doc/rascal`; `DESTDIR` is supported for packaging |
| `make uninstall` | remove what `make install` installed, with the same `PREFIX` / `DESTDIR` |
| `make release` | the same as `make dist`, packaged as `dist/rascal-<version>-<platform>.tar.gz` |
| `make dependencies-archive` | every dependency download in `dist/rascal-<version>-dependencies.tar` |
| `make dist` | stripped binary and `LICENSES.txt` in `dist/rascal-<version>-<platform>/` |
| `make fetch` | download and unpack sources only, eg. before going offline |
| `make clean` | remove this platform's build directory, keeping downloads |
| `make distclean` | remove `build/` and `dist/` entirely |
| `DEBUG=1` | `-O0 -g`, and `make install` leaves the binary unstripped |
| `PREFIX=` | install location, eg. `make install PREFIX=$HOME/.local` |
| `CC=`, `CXX=`, `CFLAGS=` | the usual |

## Releasing

Releases are built by `.github/workflows/release.yml` when a version tag is pushed. To release:
1. Set `VERSION` in the Makefile, and commit.
2. Tag the commit and push the tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The workflow checks that the tag matches `VERSION`, then builds, tests and packages each platform, creates the GitHub release, and updates the Homebrew formula in [samuelwbaird/homebrew-tap](https://github.com/samuelwbaird/homebrew-tap). See [Building](docs/technical/building.md#releases) for the details, including the `HOMEBREW_TAP_TOKEN` secret the tap needs.
