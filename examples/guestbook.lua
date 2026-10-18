-- guestbook: a small web app with live updates by long polling
--
--   rascal examples/guestbook.lua [port]      serve until stopped (default 8081), then open it in a browser
--   rascal examples/guestbook.lua --test      add entries and check a long poll sees them, then exit
--
--   guestbook thread   owns the entries, in a rascal.stowage log (in memory)
--                      serves guestbook.store (REP)       add(name, message) -> entry, list(after) -> entries
--                      serves guestbook.events (PUB)      added(entry), whenever an entry is added
--   server thread      serves http
--                      GET  /                             the page, from examples/guestbook_static
--                      GET  /api/entries?after=<id>       entries after an id
--                      GET  /api/entries?after=<id>&wait=1 the same, but waits (up to 25s) until there are some
--                      POST /api/entries                  add an entry, { name, message } as JSON
--
-- The http handlers call the store on a DEALER connection, so a call only
-- holds up its own request. A request that waits parks on a token of its own
-- with loop:suspend, and is resumed either when the store publishes that an
-- entry was added, or by its own timeout timer.

local http = require('rascal.http')
local services = require('rascal.services')
local threads = require('rascal.threads')
local prelude = require('prelude')
local cjson = require('cjson')

local test = arg[1] == '--test'
local port = (not test and tonumber(arg[1])) or 8081
local static_directory = (arg[0]:match('^(.*)/[^/]*$') or '.') .. '/guestbook_static/'

-- the guestbook, which owns the entries ------------------------------------------------------

threads.start(function ()
	local services = require('rascal.services')
	local stowage = require('rascal.stowage')

	local entries = stowage()
	local store, events
	local guestbook = {}

	function guestbook:add(name, message)
		local entry = { name = name, message = message, time = os.time() }
		entries:log_append('entries', entry)
		entry.id = entries:log_read_reverse('entries', 1)[1].id
		events:added(entry)
		return entry
	end

	function guestbook:list(after)
		local list = {}
		for _, logged in ipairs(entries:log_read('entries', after)) do
			logged.data.id = logged.id
			list[#list + 1] = logged.data
		end
		return list
	end

	function guestbook:stop()
		store:close()
		events:close()
	end

	store = services.serve('guestbook.store', 'REP', {
		add = 'name:string, message:string -> entry:table',
		list = 'after:number -> entries:table',
		stop = '',
	}, guestbook)
	events = services.serve('guestbook.events', 'PUB', {
		added = 'entry:table',
	})
end)

-- the http server ----------------------------------------------------------------------------

local store = services.connect('guestbook.store', 'DEALER')

-- requests waiting for new entries, each parked on its own token
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

local function entries_after(after)
	-- an empty list is still a JSON array
	return setmetatable(store:list(after), cjson.array_mt)
end

local server = http.server()

server:equal('/api/entries', function (request)
	if request.method == 'POST' then
		local input = request:json() or {}
		if type(input.name) ~= 'string' or type(input.message) ~= 'string' or input.name == '' or input.message == '' then
			return http.json({ error = 'name and message are required' }, 400)
		end
		return http.json(store:add(input.name:sub(1, 40), input.message:sub(1, 400)))
	end

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
end)

server:handle(http.static(static_directory))

if not test then
	log('guestbook on http://127.0.0.1:' .. port .. '/')
	server:listen('tcp://*:' .. port)
	return
end

-- in test mode, one thread long polls while another adds entries --------------------------

local endpoint = server:listen('tcp://127.0.0.1:*')
local base = 'http://127.0.0.1:' .. endpoint:match(':(%d+)$')
local results = require('rascal.messaging').bind('PULL', 'guestbook.results')
local received = {}
loop:add_socket(results, function (socket)
	received[#received + 1] = socket:recv()
	if #received < 2 then
		return
	end
	loop:remove_socket(socket)
	socket:close()
	-- stop everything, so the process exits
	server:close()
	subscription:close()
	loop:schedule(function ()
		store:stop()
		store:close()
	end)
	table.sort(received)
	local expected = 'added: 1 entry|long poll: hello from the test'
	if table.concat(received, '|') ~= expected then
		log('expected ' .. expected .. ', got ' .. table.concat(received, '|'))
		os.exit(1)
	end
	log('guestbook passed')
end)

-- waits for an entry
threads.start(function (base)
	local http = require('rascal.http')
	local entries = http.fetch('GET', base .. '/api/entries?after=0&wait=1'):json()
	local push = require('rascal.messaging').connect('PUSH', 'guestbook.results')
	push:send('long poll: ' .. (entries[1] and entries[1].message or 'nothing'))
	push:close()
end, base)

-- adds an entry, once the long poll is waiting
threads.start(function (base)
	local http = require('rascal.http')
	require('lzmq.timer').sleep(300)
	local page = http.fetch('GET', base .. '/')
	assert(page.status == 200 and page.body:find('Guestbook', 1, true), 'the page is served')
	local missing = http.fetch('POST', base .. '/api/entries', '{}', { ['content-type'] = 'application/json' })
	assert(missing.status == 400, 'an entry needs a name and message')
	local added = http.fetch('POST', base .. '/api/entries', '{"name":"test","message":"hello from the test"}', { ['content-type'] = 'application/json' })
	local count = #http.fetch('GET', base .. '/api/entries?after=0'):json()
	local push = require('rascal.messaging').connect('PUSH', 'guestbook.results')
	push:send('added: ' .. count .. ' entry')
	push:close()
end, base)
