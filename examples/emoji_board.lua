-- emoji board: a live board of emoji reactions, shared by everyone, over websockets
--
--   rascal examples/emoji_board.lua [port]      serve until stopped (default 8082), then open it in a browser
--   rascal examples/emoji_board.lua --test      check reactions reach every websocket, then exit
--
--   board thread   serves emoji_board.reactions (PULL), the events of every websocket:
--                  opened and closed keep the set of open websockets, and each
--                  reaction in a message is sent to every one of them
--   main thread    serves http
--                  GET /             the page, from examples/emoji_board_static
--                  GET /emoji        the emoji that can be sent, as json
--                  GET /live         upgrades to a websocket, sending reactions to emoji_board.reactions
--                  and serves emoji_board.send (PULL), to send to the websockets by name
--
-- A websocket is held by the http server, which sends its messages, as
-- tables decoded from json, to the service named when it was accepted. Any
-- thread can send to it by name, through the server's websockets service.

local http = require('rascal.http')
local crypto = require('rascal.crypto')
local threads = require('rascal.threads')

local test = arg[1] == '--test'
local port = (not test and tonumber(arg[1])) or 8082
local static_directory = (arg[0]:match('^(.*)/[^/]*$') or '.') .. '/emoji_board_static/'

local emoji = { '👍', '❤️', '😂', '😮', '🎉', '👏', '🔥', '🦆' }

-- the board, which sends each reaction to every websocket -----------------------------------

threads.start(function (emoji)
	local services = require('rascal.services')

	local allowed = {}
	for _, e in ipairs(emoji) do
		allowed[e] = true
	end

	local board = {
		websockets = {},	-- the names of the open websockets
	}
	local service, sender

	function board:opened(name, context)
		self.websockets[name] = true
	end

	function board:closed(name, context, code)
		self.websockets[name] = nil
	end

	function board:message(name, context, message)
		if type(message) == 'table' and allowed[message.emoji] then
			-- connected when first needed, as the http server serves it
			sender = sender or services.connect('emoji_board.send')
			for other in pairs(self.websockets) do
				sender:send(other, { emoji = message.emoji })
			end
		end
	end

	-- in --test mode, stop serving so the example exits
	function board:stop()
		service:close()
	end

	service = services.serve('emoji_board.reactions', 'PULL', {
		opened = 'name:string, context:*',
		message = 'name:string, context:*, message:*',
		closed = 'name:string, context:*, code:number',
		stop = '',
	}, board)
end, emoji)

-- the http server ----------------------------------------------------------------------------

local server = http.server({ websockets = 'emoji_board.send' })

server:equal('/emoji', http.json(emoji))

server:equal('/live', function (request)
	-- everyone is welcome, each with a websocket of their own
	return http.websocket({ name = crypto.random_token(16), service = 'emoji_board.reactions' })
end)

server:handle(http.static(static_directory))

if not test then
	log('emoji board on http://127.0.0.1:' .. port .. '/')
	server:listen('tcp://*:' .. port)
	return
end

-- in test mode, two websockets send reactions, and each should see both ---------------------

local endpoint = server:listen('tcp://127.0.0.1:*')
local results = require('rascal.messaging').bind('PULL', 'emoji_board.results')
loop:add_socket(results, function (socket)
	local result = socket:recv()
	loop:remove_socket(socket)
	socket:close()
	-- stop everything, so the process exits
	server:close()
	require('rascal.services').connect('emoji_board.reactions'):stop()
	if result ~= 'passed' then
		log(result)
		os.exit(1)
	end
	log('emoji board passed')
end)

threads.start(function (port)
	local websocket = require('rascal.http.websocket')
	local base = 'ws://127.0.0.1:' .. port .. '/live'
	local function check()
		local alice = websocket.connect(base)
		local bob = websocket.connect(base)
		alice:send({ emoji = '🎉' })
		local seen_by_alice, seen_by_bob = alice:receive(5000), bob:receive(5000)
		if not (seen_by_alice and seen_by_alice.emoji == '🎉' and seen_by_bob and seen_by_bob.emoji == '🎉') then
			return 'a reaction did not reach both websockets'
		end
		bob:send({ emoji = 'not an emoji on the board' })
		bob:send({ emoji = '🦆' })
		local next_for_alice = alice:receive(5000)
		if not (next_for_alice and next_for_alice.emoji == '🦆') then
			return 'a reaction that is not on the board was sent on'
		end
		alice:close()
		bob:close()
		return 'passed'
	end
	local ok, result = pcall(check)
	local push = require('rascal.messaging').connect('PUSH', 'emoji_board.results')
	push:send(ok and result or tostring(result))
	push:close()
end, endpoint:match(':(%d+)$'))
