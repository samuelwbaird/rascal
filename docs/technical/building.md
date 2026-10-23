# Building

rascal builds with plain `make`, on macOS and Linux. It needs `make`, a C and C++ compiler, `curl` and `tar`:
- **macOS:** `xcode-select --install`
- **Debian or Ubuntu:** `apt-get install build-essential curl`
- **Alpine:** `apk add build-base linux-headers curl`

Everything else is downloaded at pinned versions, checked against a sha256, and compiled from source.

```bash
make            # builds build/<platform>/bin/rascal
make test       # runs the test suite and checks the executable's linkage
make install    # installs to /usr/local/bin, or eg. make install PREFIX=$HOME/.local
```

`make -j` builds in parallel.

## How the build works

The [`Makefile`](../../Makefile) has the generic rules, and [`config.mk`](../../config.mk) the platform detection and options. Each dependency is declared in its own file, [`deps/<name>.mk`](../../deps), giving its version, download, checksum, sources and modules. The Makefile includes every one, then generates the same rules for each:

1. **Fetch.** [`scripts/fetch.sh`](../../scripts/fetch.sh) downloads the archive into `build/downloads/`, checks its sha256, unpacks it into `build/<platform>/src/<name>/`, and applies any patches from `patches/<name>/`. Downloads are cached and shared between platforms.
2. **Compile.** Each dependency's C sources are compiled with the Lua headers and every dependency's include directories. libzmq, which is C++ with its own configure script, is built as a static library instead.
3. **Embed.** A list of every compiled in C module and embedded Lua module is written to `build/<platform>/gen/modules.list`. [`tools/embed.lua`](../../tools/embed.lua), run with a plain Lua interpreter built first, turns it into `modules.c`: tables of the C modules, the Lua modules' source, and the dependencies' versions.
4. **Link.** rascal's own C in [`src/`](../../src), `lua.c` and `modules.c` are linked with every dependency into `build/<platform>/bin/rascal`.

Some details of how it rebuilds:
- **Changing a dependency** re-unpacks it, and rebuilds everything. This includes changing its `.mk` file, or one of its patches.
- **Adding or removing a Lua module** under `lua/` regenerates `modules.c`, as does editing one.
- **Header dependencies** are tracked for rascal's own C.

`make info` shows the platform, options, and each dependency's pinned version.

### Output

All output is under `build/<platform>/`, so macOS and Linux builds can share one checkout, and its downloads:

| | |
| --- | --- |
| `build/downloads/` | the downloaded archives, shared by every platform |
| `build/<platform>/src/` | each dependency, unpacked and patched |
| `build/<platform>/obj/` | object files |
| `build/<platform>/gen/` | the generated `modules.list` and `modules.c` |
| `build/<platform>/bin/rascal` | the executable |
| `build/<platform>/LICENSES.txt` | every dependency's licence, from `make licenses` |
| `dist/` | packages from `make dist`, `make release` and `make dependencies-archive` |

The platform is eg. `darwin-arm64`, `linux-x86_64`, or `linux-x86_64-static` for a fully static build.

## Targets

| | |
| --- | --- |
| `make` | builds the executable |
| `make test` | builds, runs the [tests](testing.md), and checks the executable's linkage |
| `make check-linkage` | only checks the linkage |
| `make install` | installs the stripped executable to `$PREFIX/bin`, and the licences to `$PREFIX/share/doc/rascal`. `DESTDIR` is supported for packaging |
| `make uninstall` | removes what `make install` installed, with the same `PREFIX` and `DESTDIR` |
| `make fetch` | downloads and unpacks every dependency, eg. before going offline |
| `make licenses` | generates `LICENSES.txt` |
| `make dist` | the stripped executable and `LICENSES.txt`, in `dist/rascal-<version>-<platform>/` |
| `make release` | the same, packaged as `dist/rascal-<version>-<platform>.tar.gz` |
| `make dependencies-archive` | every dependency download, in `dist/rascal-<version>-dependencies.tar` |
| `make info` | the platform, options and dependency versions |
| `make version` | the version, from `VERSION` in the Makefile |
| `make clean` | removes this platform's build directory, keeping the downloads |
| `make distclean` | removes `build/` and `dist/` entirely |

## Options

Options are set on the command line, eg. `make DEBUG=1`.

| | |
| --- | --- |
| `STATIC=deps` | the default: every third party library is linked statically, see below |
| `STATIC=full` | a fully static executable, for Linux with musl |
| `DEBUG=1` | builds with `-O0 -g`, and `make install` leaves the executable unstripped |
| `PREFIX=` | where `make install` installs, by default `/usr/local` |
| `DESTDIR=` | a root to stage `make install` under, for packaging |
| `CC=`, `CXX=`, `CFLAGS=`, `LDFLAGS=` | as usual |

Changing options doesn't clean the build. Run `make clean` after changing `CC` or `CFLAGS`, so that everything is compiled the same way. `STATIC=full` builds into its own directory anyway.

## Static linking

**macOS** doesn't allow fully static executables. All third party code is linked statically, and the executable depends only on `libSystem` and `libc++`. It runs on macOS 12 and later, whatever it's built on, as `MACOSX_DEPLOYMENT_TARGET` is set to 12.0.

**Linux** has two choices:
- **`STATIC=deps`**, the default, links every dependency statically against glibc, with libstdc++ and libgcc also linked statically. The executable depends only on glibc. It exports the Lua API, so external C modules can still be loaded with `require`, from `RASCAL_CPATH`.
- **`STATIC=full`** builds a completely static executable. It's meant for musl, eg. Alpine, and the result runs on any Linux of the same architecture, including in a `FROM scratch` container. External C modules can't be loaded in this mode. This is how the Linux releases are built.

`make test` checks this with [`scripts/check-linkage.sh`](../../scripts/check-linkage.sh), which fails if the executable links any library other than those expected.

## Linux builds with Docker

[`scripts/docker-build.sh`](../../scripts/docker-build.sh) builds for Linux in a container, using this checkout, so Linux builds can be made from macOS:

```bash
scripts/docker-build.sh alpine          # fully static, build/linux-<arch>-static/bin/rascal
scripts/docker-build.sh ubuntu          # glibc, build/linux-<arch>/bin/rascal
DOCKER_PLATFORM=linux/amd64 scripts/docker-build.sh alpine     # x86_64 from Apple silicon (emulated, slow)
scripts/docker-build.sh alpine all test release                # with other make targets
```

The make targets default to `all test`. The build environments are in [`docker/`](../../docker).

## Building offline

Every dependency is downloaded once, into `build/downloads/`. To build without the network:
- **From a checkout:** run `make fetch` first, while online.
- **From a release:** each release includes `rascal-<version>-dependencies.tar`, with every dependency download. Extract it into `build/`, then `make`:

```bash
tar -xf rascal-0.1.0-dependencies.tar -C build
make
```

## Releases

Releases are built by [`.github/workflows/release.yml`](../../.github/workflows/release.yml) when a version tag is pushed. To release:
1. Set `VERSION` in the Makefile, and commit.
2. Tag the commit and push the tag:

```bash
git tag v0.1.0 && git push origin v0.1.0
```

The workflow checks the tag matches `VERSION`, then:
1. **Builds, tests and packages each platform:**
   - `darwin-arm64` and `darwin-x86_64` on macOS runners
   - `linux-x86_64-static` and `linux-aarch64-static` in Alpine
2. **Creates the GitHub release,** with the dependencies archive and `SHA256SUMS` added.
3. **Updates the Homebrew formula** in [samuelwbaird/homebrew-tap](https://github.com/samuelwbaird/homebrew-tap), generated by [`scripts/homebrew-formula.sh`](../../scripts/homebrew-formula.sh).

Updating the tap needs the `HOMEBREW_TAP_TOKEN` secret: a fine-grained token with *Contents: Read and write* on the tap repository only. Without it, the workflow skips updating the tap. The formula for an existing release can be generated by hand:

```bash
scripts/homebrew-formula.sh 0.1.0 SHA256SUMS > Formula/rascal.rb
```

[`install.sh`](../../install.sh) installs the latest release, or builds from source where there's no prebuilt executable. See the [README](../../README.md#installing).
