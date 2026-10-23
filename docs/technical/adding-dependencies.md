# Adding dependencies

rascal has no package manager. A library becomes part of rascal by adding it to the build, so it's compiled into the executable at a pinned version. This page covers adding Lua modules, C libraries and Lua C modules, and patching them.

Each addition should be worth having in every rascal program, small, and portable. It shouldn't add dynamic dependencies, or need tools beyond a C compiler.

## A Lua module

Put it under [`lua/`](../../lua), and run `make`. The module name comes from its path:

| File | require |
| --- | --- |
| `lua/net/http.lua` | `require('net.http')` |
| `lua/net/init.lua` | `require('net')` |

rascal's own modules live in `lua/rascal/`. Only `prelude` and `init` are at the top level. Don't add `lua/rascal/init.lua`, unless it's meant to be `require('rascal')` itself.

A module with its own licence should have it in `lua/LICENSE.<name>`, which is then included in `LICENSES.txt`.

While working on a module, run it from the file rather than rebuilding each time:

```bash
RASCAL_PREFER_FILES=1 RASCAL_PATH='lua/?.lua;lua/?/init.lua' build/darwin-arm64/bin/rascal app.lua
```

### Conventions for embedded modules

Embedded modules shouldn't depend on the [init](../modules/init.md) script having run, since rascal can be started with `--no-init`. Require dependencies as locals, rather than using init's globals, and use the global `log` only if it's there:

```lua
local prelude = require('prelude')             -- rather than the global class or list
local log = rawget(_G, 'log') or print         -- init's log, or print without init
```

[`lua/rascal/database.lua`](../../lua/rascal/database.lua) is a good example.

Other conventions:
- **Errors:** raise errors, with messages starting with the module's name, eg. `'database: invalid name'`.
- **State per thread:** each thread is its own Lua state, with its own copy of any module-level state, such as caches or open connections. A module can't share state between threads, except through messaging.
- **Header comments:** start the file with a comment showing how the module is used, then describe what it does.
- **Documentation:** add a page to [`docs/modules/`](../modules), and link it from the [index](../index.md).
- **Tests:** add tests in [`tests/rascal/`](../../tests/rascal), see [Testing](testing.md).

## A C library or Lua C module

Add `deps/<name>.mk`, and it's picked up automatically. A typical one:

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

Leave `foo_SHA256` empty at first. The fetch then fails, and prints the archive's actual hash to pin.

### Variables

| | |
| --- | --- |
| `<name>_VERSION` | the version, shown by `make info` and `require('rascal.build').dependencies` |
| `<name>_HOME` | the project's home page, included in `LICENSES.txt` |
| `<name>_URL` | the archive to download, a `.tar.gz` or `.tgz` with a single top level directory |
| `<name>_SHA256` | the archive's sha256 |
| `<name>_SRCS` | the C sources to compile, relative to the unpacked archive |
| `<name>_CFLAGS` | flags for compiling its sources |
| `<name>_INCLUDES` | include flags for its headers, used when compiling every dependency and rascal itself |
| `<name>_CMODULES` | the C modules it provides, as `module.name:luaopen_function` |
| `<name>_LUA` | Lua files it provides, as `module.name:path/in/archive.lua` |
| `<name>_LICENSE` | its licence file, in the archive |

Optional variables:

| | |
| --- | --- |
| `<name>_PRUNE` | paths to delete after unpacking, eg. bundled copies of libraries rascal already builds. [`deps/lsqlite3.mk`](../../deps/lsqlite3.mk) does this with SQLite |
| `<name>_LICENSE_LINES` | a line range, eg. `1,27`, when the licence is inside a source file |
| `<name>_LICENSE_NOTE` | text to use when there's no licence file, eg. for public domain code |
| `<name>_LIB` | a static library to link, for a library with its own build system, along with the rule that builds it |

The `lua.mk` file is included first, as its headers are needed by everything else. The others are included in name order.

### Libraries with their own build system

Most dependencies are compiled by the generic rules, from their list of sources. A library that needs its own build system, eg. to generate headers or compile C++, sets `<name>_LIB` to a static library, and provides the rule to build it from the unpacked source. [`deps/zeromq.mk`](../../deps/zeromq.mk) does this for libzmq, with its configure script.

Turn off anything optional that the build system would detect. Anything it finds on the build machine would otherwise become a dynamic dependency of the executable, and `make test` fails its linkage check.

### C modules that create Lua states

A C module that creates new Lua states, as llthreads2 does, must open them with `rascal_openlibs` instead of `luaL_openlibs`. Otherwise those states won't have the compiled in and embedded modules, or run init.

This usually needs no patch. Add `-DluaL_openlibs=rascal_openlibs` to its `_CFLAGS`, as [`deps/llthreads2.mk`](../../deps/llthreads2.mk) does.

### After adding it

- **Tests:** add a test in [`tests/dependencies/`](../../tests/dependencies) that requires it and exercises what rascal uses it for.
- **Documentation:** add it to the [Third party dependencies](../dependencies.md) page, with a link to its documentation.
- **Check the build:** run `make test`, on macOS and in a fully static Linux build, which checks it adds no dynamic dependencies:

```bash
make test
scripts/docker-build.sh alpine
```

## A fix to a dependency

Put a `-p1` patch in `patches/<name>/`, eg. `patches/lzmq/0001-include-stdlib.patch`. Patches are applied in name order whenever the dependency is unpacked, and changing a patch re-unpacks the dependency and rebuilds.

Start the patch with a description of what it changes, and why. `patch` ignores text before the first diff.

Patches should be small and few. Where a change can be made with a compiler flag instead, eg. `-DluaL_openlibs=rascal_openlibs`, prefer that.

## Updating a dependency

1. Change `<name>_VERSION` in its `.mk` file, and empty `<name>_SHA256`.
2. Run `make`, and pin the hash it prints.
3. Check that its patches still apply, and are still needed.
4. Update the version on the [dependencies](../dependencies.md) page.
5. Run `make test`.
