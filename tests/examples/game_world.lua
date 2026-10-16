-- game world: one game server thread, and client threads that join and play
--
--   game_world.join         REQ/REP    a client joins, and is given its name, score and the leaderboard
--   game_world.input        PUSH/PULL  clients push the points they gain
--   game_world.leaderboard  PUB/SUB    the server publishes the leaderboard, and game over
--
-- Input is not handled as it arrives. The server runs a frame timer, and
-- each frame applies the input waiting since the last frame, then publishes
-- the leaderboard if anything changed. How often clients send input does not
-- decide how often the server works, or how often it broadcasts.
--
-- Each thread is single threaded, even with several sockets and timers, so
-- its code stays simple: a client subscribes before it joins, and ignores
-- any leaderboard that arrives before it has a name. The leaderboard is the
-- whole state, so one missed or ignored is replaced by the next.
--
-- The server's frames, and each client's play, are each a loop in a coroutine
-- (see loop:schedule), waiting between steps with coroutine.yield(milliseconds).
--
-- The game ends after a set number of frames: the server publishes game over
-- and closes its services, and each client stops when it sees game over, so
-- every thread completes and the process exits.

local threads = require('rascal.threads')

local frames_per_second = 10
local game_seconds = 3
local client_count = 3

-- the game server ----------------------------------------------------------------------------

local game_world_thread = [==[
	local frames_per_second, game_seconds = ...
	local prelude = require('prelude')
	local services = require('rascal.services')

	local world = {
		scores = {},
		waiting_input = {},
	}

	-- names not yet taken
	local names = prelude.list({ 'cat', 'owl', 'fox', 'eel', 'yak', 'bat', 'elk', 'gnu' })

	function world:leaderboard()
		local board = {}
		for name, score in pairs(self.scores) do
			board[#board + 1] = { name = name, score = score }
		end
		table.sort(board, function (a, b) return a.score > b.score end)
		return board
	end

	-- requested by a client to join the game
	function world:join()
		local name, index = names:random()
		names:remove(index)
		self.scores[name] = 0
		log(name .. ' joined')
		return name, 0, self:leaderboard()
	end

	-- pushed by clients, and held until the next frame
	function world:add_points(name, points)
		self.waiting_input[#self.waiting_input + 1] = { name = name, points = points }
	end

	local join_service = services.serve('game_world.join', 'REP', {
		join = '-> name:string, score:number, leaderboard:table',
	}, world)
	local input_service = services.serve('game_world.input', 'PULL', {
		add_points = 'name:string, points:number',
	}, world)
	local leaderboard_service = services.serve('game_world.leaderboard', 'PUB', {
		leaderboard = 'leaderboard:table',
		game_over = 'leaderboard:table',
	})

	-- each frame, apply the waiting input, and publish the leaderboard if it changed
	function world:update_frame()
		if #self.waiting_input == 0 then
			return
		end
		for _, input in ipairs(self.waiting_input) do
			self.scores[input.name] = self.scores[input.name] + input.points
		end
		self.waiting_input = {}
		leaderboard_service:leaderboard(self:leaderboard())
	end

	-- run the frames for the length of the game, then end it and stop serving
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
]==]

-- a game client ------------------------------------------------------------------------------

local game_client_thread = [==[
	local join_delay, input_interval = ...
	local services = require('rascal.services')

	local client = {
		name = nil,
		playing = true,
	}
	local subscription

	function client:show(leaderboard, label)
		local entries = {}
		for _, entry in ipairs(leaderboard) do
			entries[#entries + 1] = entry.name .. ' ' .. entry.score
		end
		log(self.name .. ' sees ' .. (label or '') .. table.concat(entries, ', '))
	end

	-- published by the game server
	function client:leaderboard(leaderboard)
		if self.name then
			self:show(leaderboard)
		end
	end

	function client:game_over(leaderboard)
		self.playing = false
		subscription:close()
		if self.name then
			self:show(leaderboard, 'final scores ')
		end
	end

	-- join after a delay, then send input until the game is over
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
]==]

-- start the game, then the clients -------------------------------------------------------------

threads.start(game_world_thread, frames_per_second, game_seconds)
for i = 1, client_count do
	threads.start(game_client_thread, math.random(100, 1000), math.random(200, 500))
end
