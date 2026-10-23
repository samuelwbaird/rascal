# Shared cache

[`examples/shared_cache.lua`](../../examples/shared_cache.lua): a cache server thread, used through a client object in each thread. Each client keeps its own copy of what it reads, and the server tells every client when a key changes.

```bash
rascal examples/shared_cache.lua
```

```
web worker 2 served 849 pages (11 not found), 823 from its own cache, 37 from the cache server
web worker 1 served 839 pages (17 not found), 814 from its own cache, 42 from the cache server
editor made 20 edits
```

Here the cache holds the content of a small website. An editor renders pages into the cache, and keeps editing them. Meanwhile, web workers serve requests for pages from the latest rendered version, rather than each rendering pages on demand.

## What it shows

- **One thread owning shared state, while every thread reads it quickly.** Most reads are answered from the client's own copy, without leaving its thread. Only keys it doesn't have are asked of the server.
- **Invalidation with publish and subscribe.** Whenever a key is set or cleared, the server publishes the key, and every client forgets it, so its next read fetches the latest value.
- **The same class in every thread.** `threads.code` passes the client class's constructor function to each thread as an argument, and `threads.load` turns it back into a function there.
- **Weak tables as a cache.** Entries the client holds can be collected when nothing else uses them.

```
cache.update       PUSH/PULL   set(key, value), clear(key)
cache.get          REQ/REP     get(key) -> value
cache.invalidate   PUB/SUB     the server publishes invalidate_key(key) on every set or clear
```

Clients aren't perfectly in sync: a read can briefly return a value that has just changed elsewhere. But they stay close to up to date, with very little overhead.

This isn't a general purpose cache library. It's an ad hoc arrangement of a few services, fitted to one situation, and meant to be easy to put together and change to suit. See [Architecture](../technical/architecture.md#library-modules-and-examples).

## The source

### Settings

[Lines 30–33.](../../examples/shared_cache.lua#L30-L33) Four pages, and two seconds of editing and serving.

### The client class

[Lines 35–89.](../../examples/shared_cache.lua#L35-L89) The cache client is a [prelude class](../modules/prelude.md#classes), made by a function, `cache_client_class()`, so it can be passed to each thread. In an application, this could be one of its own modules instead.

Creating a client connects to all three services:

```lua
function cache_client:init()
	self.entries = prelude.weak()
	self.from_client = 0
	self.from_server = 0
	self.update = services.connect('cache.update')
	self.lookup = services.connect('cache.get')
	self.subscription = services.subscribe('cache.invalidate', self)
end
```

The client subscribes to `cache.invalidate` with itself as the target, so the server's `invalidate_key` calls are made on its `invalidate_key` method.

`get` returns the client's own entry if it has one, otherwise asks the server, and keeps what it's given:

```lua
function cache_client:get(key)
	local value = self.entries[key]
	if value ~= nil then
		self.from_client = self.from_client + 1
		return value
	end
	self.from_server = self.from_server + 1
	value = self.lookup:get(key)
	self.entries[key] = value
	return value
end
```

`set` and `clear` change the client's own entry, then push the change to the server. `invalidate_key`, called by the server, forgets an entry.

`entries` is a weak table, so entries are let go when nothing else in the thread uses them. Lua never removes strings from weak tables, only tables, so each page is a table. A key with no value isn't kept by the client, so it's asked of the server on every read.

### Passing the class to threads

[Line 91.](../../examples/shared_cache.lua#L91) A function can't be passed to a thread as an argument, but `threads.code` turns it into a string that can be:

```lua
local cache_client_code = threads.code(cache_client_class)
```

Each thread turns it back into the function, and calls it for the class:

```lua
local cache_client = require('rascal.threads').load(cache_client_code)()
local cache = cache_client()
```

`threads.code` checks the function as `threads.start` does, so it can't use any locals from outside it.

### The cache server

[Lines 95–126.](../../examples/shared_cache.lua#L95-L126) The server holds every entry in a plain table, and publishes each key as it changes:

```lua
function cache:set(key, value)
	self.entries[key] = value
	invalidate:invalidate_key(key)
end
```

The same `cache` table is served for updates (PULL) and for reads (REP). `cache.invalidate` is a PUB service, whose service object publishes the calls.

The server publishes to every client, including the one that made the change. That client's next read then fetches the value from the server. This keeps the client simple, at the cost of one extra request.

### Stopping the server

[Lines 128–134.](../../examples/shared_cache.lua#L128-L134) The server closes its services after the editor and workers are done, half a second after their running time. This is the simplest way to end the example. An application's cache server would usually run for as long as the process does.

### The editor

[Lines 139–180.](../../examples/shared_cache.lua#L139-L180) The editor renders each page into the cache, as a table with its title, version and HTML. It then edits a random page every 100ms, occasionally taking the news page down for a while:

```lua
while messaging.utc_time() < finish do
	coroutine.yield(100)
	local path = prelude.list(pages):random()
	if path == '/news' and math.random(1, 4) == 1 then
		cache:clear(path)
	else
		render(path)
	end
	edits = edits + 1
end
```

When it's done, it closes its client. That closes the subscription, which is the only socket in its loop, so the editor thread ends.

### The web workers

[Lines 184–210.](../../examples/shared_cache.lua#L184-L210) Each web worker reads a random page every 2ms, as if serving requests for it, and counts:
- how many pages were found, or not found
- how many came from its own copy, or from the server

Most come from its own copy. A worker only asks the server for a page the first time, and after each change to it.

### Starting

[Lines 212–218.](../../examples/shared_cache.lua#L212-L218) The main thread starts the server, the editor, and two web workers, passing each the client class's code, and the settings it needs. A client connecting before the server has started simply waits for it.

## See also

- [threads.code and threads.load](../modules/rascal.threads.md#threadscodecode)
- [prelude.weak](../modules/prelude.md#preludeweakkeys-values)
- [Performance](../technical/performance.md#where-time-goes), on when a cache like this helps
