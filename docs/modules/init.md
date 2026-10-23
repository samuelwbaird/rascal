# init

[`lua/init.lua`](../../lua/init.lua) runs in every Lua state rascal creates, the main state and each thread, before anything else. It sets up a few globals, so scripts and thread code can use them directly.

```lua
-- in any script or thread, with no requires
local Point = class()
log('started', os.time())
loop:add_once(100, function () log('later') end)
```

## When it runs

It runs once the standard libraries, compiled in modules and the embedded module searcher are set up. That's before `RASCAL_INIT`, `-e`, `-l` and the script, and before the global `arg` table exists.

If it raises an error:
- in the main state, rascal exits, reporting `rascal init failed: <error>`
- in a thread, the whole process aborts

## Skipping it

`rascal --no-init script.lua` skips it, in the main state and in every thread.
- **Where the option goes:** `--no-init` must come before the script name. After the script name it's passed to the script, as an ordinary argument.
- **What it doesn't affect:** it's separate from `RASCAL_INIT` (rascal's `LUA_INIT`), which is skipped with `-E` as in standard Lua.

`require('rascal.build').initialised` is false when init was skipped.

Library modules shouldn't depend on init's globals, so that they also work under `--no-init`. See [Adding dependencies](../technical/adding-dependencies.md#conventions-for-embedded-modules).

## Globals

### prelude

`require('prelude').global()` puts everything in [prelude](prelude.md) into the globals, so `class()`, `list()`, `weak()` and the rest are available directly. `prelude` itself isn't a global, so use `require('prelude')` when you need the module.

### log(...)

Writes one line to stderr: the date and time, then each argument converted with `tostring`, separated by spaces.

```lua
log('listening on', port)    -- 2026-10-23 18:46:31 listening on 8080
```

The line is written in a single call, so lines from different threads don't interleave.

### loop

This thread's messaging loop, the same as `require('rascal.messaging').loop()`. It's for sockets, timers and coroutines: see [rascal.messaging](rascal.messaging.md#the-loop).

```lua
loop:schedule(function ()
	coroutine.yield(1000)
	log('a second later')
end)
```
