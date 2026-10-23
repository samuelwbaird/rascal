# Testing

```bash
make test                                          # builds, runs every test, and checks linkage
build/darwin-arm64/bin/rascal tests/run.lua        # runs every test
build/darwin-arm64/bin/rascal tests/run.lua tests/rascal/http.lua tests/rascal/services.lua
```

The tests are run with rascal itself, by [`tests/run.lua`](../../tests/run.lua). With no arguments it runs every test, otherwise only the files given. It prints a line for each test, and exits with an error if any failed:

```
  ok    rascal/database
  FAIL  rascal/http
  ...
19 of 20 tests passed
```

## Layout

| | |
| --- | --- |
| [`tests/dependencies/`](../../tests/dependencies) | the third party libraries compiled in, checking each is there and works as rascal uses it |
| [`tests/rascal/`](../../tests/rascal) | rascal's own modules, one file for each |
| [`examples/`](../../examples) | the examples, each also run as a test |

## Writing tests

A test is a plain Lua script, run in the test runner's process, which fails if it raises an error. There's no framework: tests use `assert`, and a few globals from the runner:

| | |
| --- | --- |
| `expect_equal(actual, expected, message)` | raises an error if the values aren't equal, showing both |
| `wait_until(condition, seconds)` | runs this thread's loop until `condition()` returns true, for up to `seconds` (default 10), returning whether it did |
| `run_rascal(command_line)` | runs rascal in a new process, returning its output (stdout and stderr, with log timestamps removed) and whether it succeeded |
| `run_rascal_script(source, options)` | runs Lua source as a script in a new process, with any command line options before it |

Use a new process with `run_rascal_script` to test anything about how a program starts or ends, eg. running to completion, `--no-init`, or a thread's error output. Tests in the runner's process share its loop, threads and service names, so each test file should use names of its own.

### Waiting, rather than timing

Tests should wait for things to happen, rather than for a fixed time. The tests run on GitHub's runners for each release, which can be much slower or busier than a development machine, so a fixed wait that's generous locally can be too short there.

```lua
-- rather than loop:sleep_ex(100) and hoping the reply has arrived
local reply
assert(wait_until(function ()
	reply = socket:recv(messaging.zmq.DONTWAIT)
	return reply ~= nil
end), 'no reply')
```

Some other ways to avoid timing:
- **Connections:** wait for a service with `services.wait`, or use a ping and reply, rather than waiting for a connection to be made.
- **Ordering:** check results that can arrive in any order without depending on that order.
- **Durations:** where a test is about time, eg. a timer or a timeout, check that it took at least as long as expected, with a wide margin above.

## Examples as tests

Each example is run in its own rascal process with `--test`, and fails if that process doesn't exit successfully.

Most examples run for a short time and finish by themselves, so they ignore `--test`. The examples that serve HTTP would otherwise run until they're stopped. With `--test` they make requests to themselves, check the responses, then close the server and exit:

```lua
local test = arg[1] == '--test'
```

A new example should finish by itself, or support `--test` in the same way, so the test suite keeps it working. An example fails its test by raising an error, or exiting with `os.exit(1)`.

## Linkage

`make test` also runs [`scripts/check-linkage.sh`](../../scripts/check-linkage.sh) on the executable, which fails if it links any dynamic library other than the platform's system libraries, or for `STATIC=full`, any at all. See [Building](building.md#static-linking).
