-- shared cache: a cache server thread, used through a client in each thread
--
--   cache.update       PUSH/PULL  set(key, value), clear(key)
--   cache.get          REQ/REP    get(key) -> value
--   cache.invalidate   PUB/SUB    the server publishes invalidate_key(key) on every set or clear
--
-- Each thread uses the cache through a cache_client, with the same set, clear
-- and get as plain Lua method calls. The client keeps its own weak map of
-- entries, so a get is usually answered without leaving the thread, and only
-- asks the server for keys it does not have. Whenever a key is set or cleared
-- the server tells every client to forget it, so the next get fetches the
-- latest value.
--
-- Clients are not perfectly in sync, a get can briefly return a value that
-- has just changed elsewhere, but they stay close to up to date with very
-- little overhead.
--
-- This is not a general purpose cache library, it is an ad hoc arrangement
-- of a few services fitted to one situation, which is meant to be easy to
-- put together and change to suit.
--
-- Here, the content of a small website: an editor renders pages into the
-- cache and keeps editing them, while web workers serve requests for pages
-- from the latest rendered version, rather than each rendering them on demand.
--
-- The weak map lets entries be collected when nothing else is using them.
-- Lua never removes strings from weak tables, so each page is a table. A key
-- with no value is not kept by the client, so is asked for on every get.

local threads = require('rascal.threads')

local pages = { '/', '/about', '/news', '/contact' }
local run_milliseconds = 2000

-- the cache client, used in each thread ------------------------------------------------------
-- (passed to each thread as source here, in an application it could sit in one of its own files)

local cache_client_source = [==[
	local prelude = require('prelude')
	local services = require('rascal.services')

	local cache_client = prelude.class()

	function cache_client:init()
		self.entries = prelude.weak()
		self.from_client = 0
		self.from_server = 0
		self.update = services.connect('cache.update')
		self.lookup = services.connect('cache.get')
		self.subscription = services.subscribe('cache.invalidate', self)
	end

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

	function cache_client:set(key, value)
		self.entries[key] = value
		self.update:set(key, value)
	end

	function cache_client:clear(key)
		self.entries[key] = nil
		self.update:clear(key)
	end

	-- published by the cache server
	function cache_client:invalidate_key(key)
		self.entries[key] = nil
	end

	function cache_client:close()
		self.subscription:close()
		self.update:close()
		self.lookup:close()
	end

	return cache_client
]==]

-- the cache server ---------------------------------------------------------------------------

local cache_server_thread = [==[
	local run_milliseconds = ...
	local services = require('rascal.services')
	local loop = require('rascal.messaging').loop()

	local cache = {
		entries = {},
	}
	local invalidate

	function cache:set(key, value)
		self.entries[key] = value
		invalidate:invalidate_key(key)
	end

	function cache:clear(key)
		self.entries[key] = nil
		invalidate:invalidate_key(key)
	end

	function cache:get(key)
		return self.entries[key]
	end

	local update_service = services.serve('cache.update', 'PULL', {
		set = 'key:string, value:*',
		clear = 'key:string',
	}, cache)
	local get_service = services.serve('cache.get', 'REP', {
		get = 'key:string -> value:*',
	}, cache)
	invalidate = services.serve('cache.invalidate', 'PUB', {
		invalidate_key = 'key:string',
	})

	-- stop serving once the editor and workers are done
	loop:add_once(run_milliseconds + 500, function ()
		update_service:close()
		get_service:close()
		invalidate:close()
	end)
]==]

-- the editor, rendering pages into the cache -------------------------------------------------

local editor_thread = [==[
	local cache_client_source, pages, run_milliseconds = ...
	local prelude = require('prelude')
	local loop = require('rascal.messaging').loop()

	local cache_client = load(cache_client_source, '=cache_client')()
	local cache = cache_client()
	local versions = {}

	local function render(path)
		versions[path] = (versions[path] or 0) + 1
		local title = path == '/' and 'Home' or path:sub(2):gsub('^%l', string.upper)
		cache:set(path, {
			path = path,
			title = title,
			version = versions[path],
			html = '<h1>' .. title .. '</h1><p>version ' .. versions[path] .. ' of ' .. path .. '</p>',
		})
	end

	-- publish every page, then keep editing pages, occasionally taking the news down for a while
	for _, path in ipairs(pages) do
		render(path)
	end

	local edits = 0
	local edit_timer = loop:add_interval(100, function ()
		local path = prelude.list(pages):random()
		if path == '/news' and math.random(1, 4) == 1 then
			cache:clear(path)
		else
			render(path)
		end
		edits = edits + 1
	end)

	loop:add_once(run_milliseconds, function ()
		edit_timer:reset()
		log('editor made ' .. edits .. ' edits')
		cache:close()
	end)
]==]

-- a web worker, serving requests for pages from the cache ------------------------------------

local web_worker_thread = [==[
	local name, cache_client_source, pages, run_milliseconds = ...
	local prelude = require('prelude')
	local loop = require('rascal.messaging').loop()

	local cache_client = load(cache_client_source, '=cache_client')()
	local cache = cache_client()
	local paths = prelude.list(pages)
	local served, not_found = 0, 0

	local request_timer = loop:add_interval(2, function ()
		local page = cache:get(paths:random())
		if page then
			served = served + 1
		else
			not_found = not_found + 1
		end
	end)

	loop:add_once(run_milliseconds, function ()
		request_timer:reset()
		log(name .. ' served ' .. served .. ' pages (' .. not_found .. ' not found), '
			.. cache.from_client .. ' from its own cache, '
			.. cache.from_server .. ' from the cache server')
		cache:close()
	end)
]==]

-- start the cache server, the editor and the web workers ------------------------------------

threads.start(cache_server_thread, run_milliseconds)
threads.start(editor_thread, cache_client_source, pages, run_milliseconds)
for i = 1, 2 do
	threads.start(web_worker_thread, 'web worker ' .. i, cache_client_source, pages, run_milliseconds)
end
