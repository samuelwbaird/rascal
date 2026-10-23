# Game world

[`examples/game_world.lua`](../../examples/game_world.lua): one game server thread, and client threads that join the game, send points, and watch the leaderboard, until the game ends.

```bash
rascal examples/game_world.lua
```

```
cat joined
cat sees cat 0
cat sees cat 10
eel joined
eel sees cat 10, eel 0
fox joined
fox sees cat 10, fox 0, eel 0
cat sees cat 10, eel 5, fox 4
...
game over
```

## What it shows

- **Three messaging patterns, each for what suits it:**
  - **request and reply** (REP), to join
  - **push** (PULL), for input that needs no reply
  - **publish and subscribe** (PUB), to broadcast the leaderboard
- **A frame timer.** The server doesn't handle input as it arrives. Each frame applies the input waiting since the last, then publishes the leaderboard if anything changed. How often clients send input doesn't decide how often the server works, or how often it broadcasts.
- **Loops in coroutines.** The server's frames, and each client's play, are each a plain loop, waiting between steps with `coroutine.yield(milliseconds)`.
- **Simple code in each thread.** Each thread does one thing at a time, even with several sockets and timers. So a client can subscribe before it joins, and simply ignore any leaderboard that arrives before it has a name.

```
game_world.join          REQ/REP     a client joins, and is given its name, score and the leaderboard
game_world.input         PUSH/PULL   clients push the points they gain
game_world.leaderboard   PUB/SUB     the server publishes the leaderboard, and game over
```

## The source

### Settings

[Lines 28–32.](../../examples/game_world.lua#L28-L32) The game runs for 3 seconds at 10 frames a second, with 3 clients.

### The world

[Lines 36–55.](../../examples/game_world.lua#L36-L55) The game server is a function, `game_world_thread(frames_per_second, game_seconds)`, started in its own thread. It requires what it uses, as it runs in a new Lua state.

The world holds each player's score, and the input waiting for the next frame. `world:leaderboard()` sorts the scores into a list, highest first. The leaderboard is the whole of the game's state, so a client that misses one simply catches up with the next.

### Joining

[Lines 57–64.](../../examples/game_world.lua#L57-L64) Each player is given a random name that's not yet taken, using [prelude list](../modules/prelude.md#lists) methods:

```lua
function world:join()
	local name, index = names:random()
	names:remove(index)
	self.scores[name] = 0
	log(name .. ' joined')
	return name, 0, self:leaderboard()
end
```

A method can return several values, and the caller receives them all, in order.

### Input

[Lines 66–69.](../../examples/game_world.lua#L66-L69) `add_points` doesn't change the scores. It holds the input until the next frame.

### Serving

[Lines 71–80.](../../examples/game_world.lua#L71-L80) The one `world` table is served as two services: `game_world.join` (REP) for joining, and `game_world.input` (PULL) for input. Then a PUB service publishes to every client:

```lua
local leaderboard_service = services.serve('game_world.leaderboard', 'PUB', {
	leaderboard = 'leaderboard:table',
	game_over = 'leaderboard:table',
})
```

A PUB service has no target object. Instead, the service object it returns has a method for each API method, which publishes the call: `leaderboard_service:leaderboard(board)`.

### Frames

[Lines 82–92.](../../examples/game_world.lua#L82-L92) Each frame applies the waiting input to the scores, and publishes the new leaderboard. With no input, nothing has changed, so nothing is published.

### The game loop

[Lines 94–105.](../../examples/game_world.lua#L94-L105) The frames run as a loop in a coroutine on the server thread's loop:

```lua
loop:schedule(function ()
	for frame = 1, game_seconds * frames_per_second do
		coroutine.yield(1000 // frames_per_second)
		world:update_frame()
	end
	leaderboard_service:game_over(world:leaderboard())
	log('game over')
	join_service:close()
	input_service:close()
	leaderboard_service:close()
end)
```

While the coroutine waits between frames, the thread handles join requests and input as they arrive.

After the last frame, it publishes game over, and closes its services. That leaves the server thread with nothing to do, so it ends.

### The client

[Lines 110–140.](../../examples/game_world.lua#L110-L140) Each client is a function, `game_client_thread(join_delay, input_interval)`. The client table is the target for the leaderboard subscription, so it has a method for each call the server publishes:
- **`leaderboard`** shows the leaderboard, once the client has a name.
- **`game_over`** stops playing, and closes the subscription.

### Playing

[Lines 142–158.](../../examples/game_world.lua#L142-L158) The client's play is also a loop in a coroutine:

```lua
loop:schedule(function ()
	coroutine.yield(join_delay)
	subscription = services.subscribe('game_world.leaderboard', client)

	local join = services.connect('game_world.join')
	local name, score, leaderboard = join:join()
	join:close()
	client.name = name
	client:show(leaderboard)

	local input = services.connect('game_world.input')
	while client.playing do
		input:add_points(client.name, math.random(1, 10))
		coroutine.yield(input_interval)
	end
end)
```

The client subscribes before it joins, so it can't miss a leaderboard published after it joined. A ZeroMQ subscription only receives what's published after it connects.

`join:join()` is a REQ call, which blocks the client thread until it returns. That's fine here, as the client has nothing else to do meanwhile. `input:add_points` is a push, which returns straight away.

The loop ends when `game_over` sets `client.playing` to false. With the subscription closed, and no timers left, the client thread ends.

### Starting

[Lines 161–166.](../../examples/game_world.lua#L161-L166) The main thread starts the server, then each client with a random delay before joining, and a random interval between inputs:

```lua
threads.start(game_world_thread, frames_per_second, game_seconds)
for i = 1, client_count do
	threads.start(game_client_thread, math.random(100, 1000), math.random(200, 500))
end
```

The main thread then waits for the threads it started, and once they've all ended, the process exits.

## See also

- [rascal.services](../modules/rascal.services.md) for REP, PULL and PUB services
- [loop:schedule](../modules/rascal.messaging.md#loopschedulefn-) for coroutines on the loop
