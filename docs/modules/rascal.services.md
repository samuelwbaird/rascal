# rascal.services

Serving an object's methods by name, and calling them from any thread. Source: [`lua/rascal/services.lua`](../../lua/rascal/services.lua).

```lua
local services = require('rascal.services')

-- in one thread, serve an object's methods
local counter = { total = 0 }
function counter:add(amount)
	self.total = self.total + amount
	return self.total
end
services.serve('counter', 'REP', { add = 'amount:number -> total:number' }, counter)

-- in any thread, connect by name (waiting until it's served) and call it
local counter = services.connect('counter')
print(counter:add(5))
```

Services are how rascal threads share work and state. Typically one thread owns a resource, eg. a database, and serves it, and other threads call that service rather than sharing the resource. See [Architecture](../technical/architecture.md#threads-own-their-state).

Services are built on [rascal.messaging](rascal.messaging.md). Each one is a ZeroMQ socket bound at `inproc://<name>`, so the calls are messages, and the serving thread handles them one at a time on its loop.

## Socket types

The socket type of a service chooses how it's called:

| Serve with | Connect with | Calls |
| --- | --- | --- |
| `'REP'` | `services.connect` | request and reply: each call returns the method's results, or raises its error |
| `'ROUTER'` | `services.connect` | as REP for the caller, but each call runs as a coroutine in the serving thread, so a method can yield or wait, and several calls can be in progress at once |
| `'PULL'` | `services.connect` | push: calls are queued and return straight away, with no results |
| `'PUB'` | `services.subscribe` | publish: each call goes to every subscriber, with no results |

A REP service answers one call at a time: a call is only received once the previous one has replied. A ROUTER service receives each call as it arrives, and replies to each when its method completes, in any order. So a ROUTER method can use `coroutine.yield`, `loop:suspend`, or calls on a DEALER connection, without holding up other callers.

```lua
-- a ROUTER method that waits until there's a job to give out
function queue:next_job()
	while self.jobs:is_empty() do
		loop:suspend(self)
	end
	local job = self.jobs[1]
	self.jobs:remove(1)
	return job
end

function queue:add_job(job)
	self.jobs:push(job)
	loop:resume(self)
end
```

## API descriptions

Each service has an API description: a table with an entry for each method that can be called, describing its parameters and results.

```lua
local api = {
	add = 'amount:number -> total:number',
	get = 'key:string -> value:*',
	clear = '',
}
```

- **Which methods are served:** only methods in the description. A call to any other method raises an error for the caller.
- **Parameters and results:** values are passed by position. The names and types are documentation, and aren't checked.
- **Value limits:** values are limited to what MessagePack can encode, see [values](rascal.messaging.md#values).
- **Reserved names:** `close` and `bind_network` can't be method names.

The description is published with the service, so a client gets its methods from the registry and needs no description of its own.

## Serving

### services.serve(name, socket_type, api, target)

Serves the methods of `target` as a service named `name`, and returns the service object.
- **Socket type:** `'REP'`, `'ROUTER'`, `'PULL'` or `'PUB'`.
- **Methods:** each is called as `target:method(...)`, with the caller's arguments.
- **Errors:** an error raised by a method, with its stack trace, is returned to a REP or ROUTER caller, and raised there as `services: <name>:<method> failed: <error>`. A PULL service logs errors instead.
- **Name clashes:** serving two services with the same name raises an error.

Serving adds the service's socket to the thread's loop, so the thread keeps running to answer calls until the service is closed. See [running to completion](rascal.messaging.md#running-to-completion).

A PUB service has no target. Instead, the returned service object has a method for each API method, which publishes the call:

```lua
local events = services.serve('events', 'PUB', { player_moved = 'id:string, x:number, y:number' })
events:player_moved('p1', 10, 20)
```

### service:close()

Stops serving, and removes the service from the registry. A REP or ROUTER service with calls in progress closes once they've replied.

A service can close itself from one of its own methods, eg. a `stop` method. The call that closes it still gets its reply.

### service:bind_network(endpoint)

Also listens on a network endpoint, eg. `'tcp://*:5555'`, and returns the endpoint bound, with any wildcard port resolved. Services are inproc only unless this is called, and it's the only way they're reachable from another process.

### services.serve_balanced(name, worker_count, api, worker, ...)

Serves a service whose calls are spread across `worker_count` worker threads, each answering the same API. It returns the service object, and callers connect to it as to any REP service.

`worker` is thread code, a function or a string, run in each worker thread with the worker's number and any further arguments. It returns the object to serve in that thread, which is served as ROUTER, so its methods can yield.

```lua
services.serve_balanced('lookup', 4, { find = 'key:string -> value:*' }, function (number)
	local database = require('rascal.database')
	local db = database('lookups.sqlite')
	return {
		find = function (self, key)
			return db:select_one('lookups', { key = key }).row
		end,
	}
end)
```

How calls are shared out:
- **Choosing a worker:** each call goes to the ready worker with the fewest calls in progress. Workers with the same number take turns.
- **Where it runs:** the balancing runs on the serving thread's loop.
- **Before any worker is ready:** calls wait until one is.
- **Closing:** `service:close()` also stops the workers, once calls in progress have replied.

Each worker has its own state, and consecutive calls from the same caller can go to different workers. So this suits APIs that are stateless, or keep their state in other services, rather than those that own state themselves. [rascal.http](rascal.http.md#httpworkerscount-build-) uses this for HTTP worker threads.

## Connecting

### services.connect(name, socket_type)

Connects to a REP, ROUTER or PULL service by name, waiting until it's served if it isn't yet. It returns a client with a method for each API method.

```lua
local counter = services.connect('counter')
local total = counter:add(5)
```

For REP and ROUTER services, the client's socket type chooses how calls wait:
- **`'REQ'`** (the default): each call blocks the calling thread until it returns. This is the simplest choice for a thread that does one thing at a time.
- **`'DEALER'`**: each call parks only the coroutine making it, until its reply, so other coroutines, timers and sockets in the thread carry on meanwhile. Calls must be made from within a coroutine, eg. in `loop:schedule` or a ROUTER method, otherwise they raise an error. Several coroutines can have calls in progress at once on the one connection.

```lua
local counter = services.connect('counter', 'DEALER')
loop:schedule(function ()
	log('total', counter:add(5))     -- this coroutine waits, the thread doesn't
end)
```

The socket type has no effect on connections to PULL services, whose calls never wait.

There's no timeout on calls. A service that never replies leaves the caller waiting.

### client:close()

Closes the connection. Closing a DEALER connection resumes any calls still waiting, raising an error in each.

A DEALER connection is only in the loop while it has calls waiting, so an idle connection doesn't keep its thread running.

### services.subscribe(name, target)

Subscribes to a PUB service by name, waiting until it's served if it isn't yet. Each published call is made on `target`, if it has that method, and other calls are ignored. It returns the subscription.

```lua
services.subscribe('events', {
	player_moved = function (self, id, x, y)
		log(id, 'moved to', x, y)
	end,
})
```

As with any ZeroMQ subscription, calls published before the subscription connects aren't received. An error in a subscriber's method is logged.

The subscription is in the thread's loop, so the thread keeps running to receive calls until it's closed with `subscription:close()`.

## The registry

Services are found by name through the registry, a ROUTER service that runs in a background thread. It's started the first time a thread uses services. Each entry has:

| | |
| --- | --- |
| `name` | the service name |
| `endpoint` | where it's served, eg. `inproc://counter` |
| `socket_type` | the socket type for clients: `'REQ'`, `'PUSH'` or `'SUB'` |
| `api` | its API description |

### services.wait(name)

Waits until a service is served, and returns its registry entry. `connect` and `subscribe` do this first.

### services.find(name)

Returns the registry entry for a service, or nil if it isn't served.
