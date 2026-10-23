# Guestbook

[`examples/guestbook.lua`](../../examples/guestbook.lua): a small web app, where visitors leave a name and message, and every open page shows new entries as they're added, by long polling.

```bash
rascal examples/guestbook.lua             # serve on port 8081, then open http://127.0.0.1:8081/
rascal examples/guestbook.lua 8082        # another port
rascal examples/guestbook.lua --test      # add entries, check a long poll sees them, then exit
```

Open it in two browser windows, and add an entry in one: it appears in both.

## What it shows

- **A thread that owns the data.** The entries are in a [rascal.stowage](../modules/rascal.stowage.md) log, owned by one thread, which serves it to the HTTP server.
- **HTTP handlers calling a service without blocking.** The handlers call the store on a DEALER connection, so each call holds up only its own request.
- **Long polling with `loop:suspend`.** A request that waits for new entries parks on a token of its own, and is resumed when the store publishes that an entry was added, or by its own timeout.
- **Publish and subscribe between threads.** The store publishes each entry as it's added, and the HTTP server's thread wakes every waiting request.

```
guestbook thread   owns the entries, in a rascal.stowage log (in memory)
                   serves guestbook.store (REP)          add(name, message) -> entry, list(after) -> entries
                   serves guestbook.events (PUB)         added(entry), whenever an entry is added
server thread      serves http
                   GET  /                                the page, from examples/guestbook_static
                   GET  /api/entries?after=<id>          entries after an id
                   GET  /api/entries?after=<id>&wait=1   the same, but waits (up to 25s) until there are some
                   POST /api/entries                     add an entry, { name, message } as JSON
```

The page, in [`examples/guestbook_static/`](../../examples/guestbook_static), shows the entries, and keeps a long poll open for more. Each time one returns, it shows the new entries, and polls again after the newest entry's id.

## The source

### Settings

[Lines 20–28.](../../examples/guestbook.lua#L20-L28) The port comes from the command line, unless it's `--test`, and the static files are found beside the script.

### The guestbook thread

[Lines 30–38.](../../examples/guestbook.lua#L30-L38) The guestbook runs in a thread of its own, started with a function that takes no arguments. Its entries are in an in memory [stowage](../modules/rascal.stowage.md) store. Pass a file name to `stowage()` to keep the entries between runs.

### Adding and listing entries

[Lines 40–55.](../../examples/guestbook.lua#L40-L55) Each entry is appended to the log of one key, `'entries'`. Log entries have ids that only increase, so the page can ask for the entries after the last one it has.

```lua
function guestbook:add(name, message)
	local entry = { name = name, message = message, time = os.time() }
	entries:log_append('entries', entry)
	entry.id = entries:log_read_reverse('entries', 1)[1].id
	events:added(entry)
	return entry
end
```

`add` reads back the new entry's id, then publishes the entry on `guestbook.events`, before replying.

`list(after)` returns the entries after an id, each with its id added.

### Serving the guestbook

[Lines 57–69.](../../examples/guestbook.lua#L57-L69) The guestbook is served as a REP service, `guestbook.store`, as it only does quick work for each call. A PUB service, `guestbook.events`, publishes each new entry. `stop` closes both, for test mode.

### Connecting from the server thread

[Line 74.](../../examples/guestbook.lua#L74) The server thread, here the main thread, connects to the store with DEALER:

```lua
local store = services.connect('guestbook.store', 'DEALER')
```

Each HTTP request is handled in its own coroutine, so with DEALER, a call to the store parks only that request's coroutine until it replies. With REQ, each call would block the whole server thread meanwhile.

### Waking waiting requests

[Lines 76–86.](../../examples/guestbook.lua#L76-L86) Requests waiting for new entries are each parked on a token of their own, kept in a list. When the store publishes that an entry was added, the subscriber resumes every waiting request:

```lua
local waiting = prelude.list()
local subscription = services.subscribe('guestbook.events', {
	added = function ()
		local tokens = waiting
		waiting = prelude.list()
		for _, token in ipairs(tokens) do
			loop:resume(token)
		end
	end,
})
```

The list is replaced before resuming, as a resumed request runs straight away, and could start waiting again.

### An empty list as JSON

[Lines 88–91.](../../examples/guestbook.lua#L88-L91) An empty Lua table would be encoded as a JSON object, `{}`. Setting `cjson.array_mt` on the list encodes it as an array, `[]`, even when it's empty.

### The entries route

[Lines 93–115.](../../examples/guestbook.lua#L93-L115) One route handles both adding and listing entries. A POST checks its JSON input, and adds the entry, replying with the entry. A GET lists the entries after an id:

```lua
local after = tonumber(request.vars.after) or 0
local entries = entries_after(after)
if #entries == 0 and request.vars.wait then
	local token = {}
	waiting:push(token)
	local timeout = loop:add_once(25000, function () loop:resume(token) end)
	loop:suspend(token)
	timeout:reset()
	entries = entries_after(after)
end
return http.json(entries)
```

With `wait`, and no entries yet, the request parks on a new token until it's resumed. That happens either when an entry is added, or after 25 seconds, by its own timer. Either way, it stops the timer, lists the entries again, and replies, with an empty list if it timed out. The page then polls again.

The timeout keeps each long poll shorter than the timeouts of browsers and proxies.

### Static files and serving

[Lines 117–123.](../../examples/guestbook.lua#L117-L123) The page and its script are static files, served after the API route. Outside test mode, the server listens on the port, and serves until it's stopped.

### Test mode

[Lines 125–152.](../../examples/guestbook.lua#L125-L152) In test mode, the server listens on a free port. Two threads then use it, each pushing a result to the main thread. Once both results arrive, the main thread:
1. closes the server and the subscription
2. stops the guestbook thread, and closes its connection to it
3. checks the results, exiting with an error if they're not as expected

The store is a DEALER connection, so `store:stop()` must be called in a coroutine, here one started with `loop:schedule`.

### The test threads

[Lines 154–176.](../../examples/guestbook.lua#L154-L176) One thread makes a long poll, and reports the message it receives. The other:
1. waits a moment, so the long poll is usually already waiting
2. checks the page is served
3. checks an entry with no name or message is rejected
4. adds an entry, and reports how many entries there are

```lua
local entries = http.fetch('GET', base .. '/api/entries?after=0&wait=1'):json()
```

If the entry happens to be added before the long poll arrives, the long poll simply returns it straight away, so the test passes either way.

## See also

- [rascal.http](../modules/rascal.http.md)
- [loop:suspend and loop:resume](../modules/rascal.messaging.md#loopsuspendkey), including timeouts
- [rascal.stowage logs](../modules/rascal.stowage.md#logs)
