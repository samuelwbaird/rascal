# Emoji board

[`examples/emoji_board.lua`](../../examples/emoji_board.lua): a live board of emoji reactions, shared by everyone. Each visitor clicks an emoji to send a reaction, and sees every visitor's reactions float up the screen, over websockets.

```bash
rascal examples/emoji_board.lua             # serve on port 8082, then open http://127.0.0.1:8082/
rascal examples/emoji_board.lua 8083        # another port
rascal examples/emoji_board.lua --test      # check reactions reach every websocket, then exit
```

Open it in two browser windows, and send a reaction in one: it appears in both.

## What it shows

- **Accepting a websocket from a handler.** `/live` is an ordinary route, which accepts the upgrade by returning `http.websocket`, naming the websocket and the service that receives its messages.
- **A service receiving websocket events.** The board is a PULL service, with an `opened`, `message` and `closed` method, in a thread of its own.
- **Sending to websockets by name, from another thread.** The board sends each reaction to every open websocket, through the service the http server serves for sending.

```
board thread   serves emoji_board.reactions (PULL), the events of every websocket:
               opened and closed keep the set of open websockets, and each
               reaction in a message is sent to every one of them
main thread    serves http
               GET /             the page, from examples/emoji_board_static
               GET /emoji        the emoji that can be sent, as json
               GET /live         upgrades to a websocket, sending reactions to emoji_board.reactions
               and serves emoji_board.send (PULL), to send to the websockets by name
```

The page, in [`examples/emoji_board_static/`](../../examples/emoji_board_static), has a button for each emoji. It sends `{ "emoji": "🎉" }` when one is clicked, and shows each reaction it receives. If its websocket closes, eg. when the server restarts, it reconnects a second later.

## The source

### Settings

[Lines 19–27.](../../examples/emoji_board.lua#L19-L27) The port comes from the command line, unless it's `--test`, and the page is found beside the script. `emoji` is the list of reactions that can be sent, used both by the board, to check each reaction, and by the page, to show its buttons.

### The board

[Lines 29–42.](../../examples/emoji_board.lua#L29-L42) The board runs in a thread of its own, started with the list of emoji. It keeps the names of the open websockets.

### Opened and closed

[Lines 44–50.](../../examples/emoji_board.lua#L44-L50) The http server calls `opened` when a websocket opens, and `closed` when it closes, for any reason. So the board's set of websockets is always the ones currently open:

```lua
function board:opened(name, context)
	self.websockets[name] = true
end

function board:closed(name, context, code)
	self.websockets[name] = nil
end
```

Every event includes the context given when the websocket was accepted. This board treats everyone the same, so it doesn't use it.

### Reactions

[Lines 52–61.](../../examples/emoji_board.lua#L52-L61) Each message from a page arrives decoded from JSON. A reaction that's on the board is sent to every open websocket, including the sender's own:

```lua
function board:message(name, context, message)
	if type(message) == 'table' and allowed[message.emoji] then
		-- connected when first needed, as the http server serves it
		sender = sender or services.connect('emoji_board.send')
		for other in pairs(self.websockets) do
			sender:send(other, { emoji = message.emoji })
		end
	end
end
```

`emoji_board.send` is served by the http server, for sending to its websockets by name. It's a PULL service, so sending never waits, and the board can send to every websocket in turn. Anything else a page sends is ignored.

### Serving the board

[Lines 63–73.](../../examples/emoji_board.lua#L63-L73) The board is served as a PULL service, `emoji_board.reactions`, whose API has the three events a websocket service needs. `stop` is only for `--test` mode, so the example can exit.

### The http server

[Lines 75–86.](../../examples/emoji_board.lua#L75-L86) The server's `websockets` option allows websocket upgrades, and names the service it serves for sending to them:

```lua
local server = http.server({ websockets = 'emoji_board.send' })

server:equal('/emoji', http.json(emoji))

server:equal('/live', function (request)
	-- everyone is welcome, each with a websocket of their own
	return http.websocket({ name = crypto.random_token(16), service = 'emoji_board.reactions' })
end)
```

A websocket starts as a GET request, which goes through the handlers like any other. `/live` accepts every one, naming each websocket randomly, as visitors are anonymous. In an app with sessions, the handler would check the session and name the websocket after it, so a reconnecting browser replaces its old websocket, and other threads can send to it without looking it up.

The page itself is a static file.

### Serving

[Lines 88–92.](../../examples/emoji_board.lua#L88-L92) Outside test mode, the server listens on the port, and serves until it's stopped.

### Test mode

[Lines 94–110.](../../examples/emoji_board.lua#L94-L110) In test mode, the server listens on a free port, and waits for a result from a thread of its own. When it arrives, it closes the server and stops the board, so the process exits.

### The test thread

[Lines 112–137.](../../examples/emoji_board.lua#L112-L137) The test thread connects two websockets with the minimal client in `rascal.http.websocket`, as two visitors would:

```lua
local alice = websocket.connect(base)
local bob = websocket.connect(base)
alice:send({ emoji = '🎉' })
local seen_by_alice, seen_by_bob = alice:receive(5000), bob:receive(5000)
```

It checks both receive the reaction, then that a reaction not on the board is ignored: bob sends one, then a 🦆, and the next reaction alice receives should be the duck.

## See also

- [rascal.http websockets](../modules/rascal.http.md#websockets)
- [Guestbook](guestbook.md), which updates its pages by long polling instead
