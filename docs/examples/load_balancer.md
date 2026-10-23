# Load balancer

[`examples/load_balancer.lua`](../../examples/load_balancer.lua): one service in front, spreading calls across several backends of different speeds, with clients that only know the service in front.

```bash
rascal examples/load_balancer.lua
```

```
client 1 made 30 lookups
client 2 made 30 lookups
client 3 made 30 lookups
lookup.fast handled 71 lookups
lookup.medium handled 33 lookups
lookup.slow handled 16 lookups
client 4 made 30 lookups
```

## What it shows

- **A ROUTER service calling other services over DEALER.** Each call to the balancer runs as a coroutine, which calls a backend, and waits for its reply. The DEALER call parks only that coroutine, so the balancer has calls in progress on every backend at once. Its code for a call is still a few plain lines.
- **Balancing with no weighting.** Each call goes to the backend with the fewest calls in progress. The fastest backend frees up soonest, so it's chosen most often: here about four times as often as the slowest.
- **Thread code as a string of source.** The backends are a string, with their arguments as `...`.
- **Shutting down as part of the work.** Each client says when it's finished. Once all have, the balancer stops the backends, and closes its own service.

```
backend threads   serve lookup.fast, lookup.medium, lookup.slow (REP)
                  lookup(key) -> value, each one call at a time
balancer thread   serves lookup (ROUTER)   lookup(key) -> value, finished()
                  with a DEALER connection to each backend
client threads    call lookup, one call after another, then finished()
```

rascal has this pattern built in, as [`services.serve_balanced`](../modules/rascal.services.md#servicesserve_balancedname-worker_count-api-worker-), which starts the workers itself. This example builds it from services, to show how it works, and so it can be adapted, eg. to backends that already exist, or to choose backends some other way.

## The source

### Settings

[Lines 22–30.](../../examples/load_balancer.lua#L22-L30) Three backends, taking 5, 10 and 20ms for each lookup, and four clients, making 30 lookups each.

### A backend

[Lines 32–58.](../../examples/load_balancer.lua#L32-L58) The backend's thread code is a string of Lua source, rather than a function. Its arguments arrive as `...`:

```lua
local backend_thread = [==[
	local name, milliseconds = ...
	local services = require('rascal.services')
	local ztimer = require('lzmq.timer')

	local backend = {}
	local service

	function backend:lookup(key)
		-- blocking, standing in for work that keeps this backend busy
		ztimer.sleep(milliseconds)
		return key .. ' from ' .. name
	end
	...
]==]
```

Each backend is a REP service, so it handles one call at a time. `lookup` blocks the backend's thread on purpose, standing in for real work.

`stop` closes the backend's service, from one of its own calls. The call still gets its reply, then the service closes, and the backend thread ends.

A function would work as well here, and is usually clearer. A string is useful for thread code that's put together or loaded at run time.

### The balancer's connections

[Lines 62–74.](../../examples/load_balancer.lua#L62-L74) The balancer connects to each backend with DEALER, and keeps a count of the calls in progress on each:

```lua
backends:push({
	name = name,
	connection = services.connect(name, 'DEALER'),
	in_progress = 0,
	handled = 0,
})
```

`services.connect` waits until each backend is served, so the balancer can start before the backends are ready.

### Balancing

[Lines 81–95.](../../examples/load_balancer.lua#L81-L95) Each call picks the backend with the fewest calls in progress, and calls it:

```lua
function balancer:lookup(key)
	local backend = backends[1]
	for _, candidate in ipairs(backends) do
		if candidate.in_progress < backend.in_progress then
			backend = candidate
		end
	end

	backend.in_progress = backend.in_progress + 1
	local value = backend.connection:lookup(key)
	backend.in_progress = backend.in_progress - 1
	backend.handled = backend.handled + 1
	return value
end
```

`backend.connection:lookup(key)` sends the call, and parks this coroutine until the reply arrives. Meanwhile, the balancer's thread receives other calls, each in its own coroutine. As every coroutine runs in the balancer's one thread, the counts need no locks.

A backend is a REP service, so it handles its calls one at a time. Calls sent while it's busy wait in its queue. That's why the count of calls in progress is a good guide to which backend will answer soonest.

### Finishing

[Lines 97–109.](../../examples/load_balancer.lua#L97-L109) Each client calls `finished` when it's done. Once all have, the balancer:
1. logs how many lookups each backend handled
2. stops each backend, and closes its connection
3. closes its own service

```lua
for _, backend in ipairs(backends) do
	log(backend.name .. ' handled ' .. backend.handled .. ' lookups')
	backend.connection:stop()
	backend.connection:close()
end
service:close()
```

The last client's `finished` call is still in progress when `service:close()` is called, so the service closes once that call has replied.

### Serving

[Lines 111–114.](../../examples/load_balancer.lua#L111-L114) The balancer is served as a ROUTER service, which is what lets each call run as a coroutine, and wait without holding up the others.

### A client

[Lines 119–128.](../../examples/load_balancer.lua#L119-L128) A client connects to `lookup`, makes its lookups one after another, then says it's finished:

```lua
local lookup = services.connect('lookup')
for i = 1, lookups do
	lookup:lookup(name .. ' key ' .. i)
end
lookup:finished()
```

To the client, `lookup` is a REP service like any other. It connects with REQ, so each call blocks the client until it returns.

### Starting

[Lines 130–140.](../../examples/load_balancer.lua#L130-L140) The main thread starts the backends, then the balancer with the backends' names, then the clients. The order doesn't matter, as every connection waits for its service to be served.

## See also

- [rascal.services](../modules/rascal.services.md#servicesconnectname-socket_type) for REQ and DEALER connections
- [services.serve_balanced](../modules/rascal.services.md#servicesserve_balancedname-worker_count-api-worker-), the built in version of this pattern
- [Work queue](work_queue.md), where workers ask for work, rather than being sent it
