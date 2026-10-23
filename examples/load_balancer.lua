-- load balancer: one service in front, spreading calls across several backends
--
--   backend threads   serve  lookup.fast, lookup.medium, lookup.slow (REP)
--                            lookup(key) -> value, each one call at a time
--   balancer thread   serves lookup (ROUTER)     lookup(key) -> value, finished()
--                     with a DEALER connection to each backend
--   client threads    call lookup, one call after another, then finished()
--
-- Clients only know the lookup service. Each call to the balancer runs as a
-- coroutine (it is a ROUTER service), which picks the backend with the fewest
-- calls in progress, calls it on that backend's DEALER connection, and returns
-- the result. The DEALER call parks only that coroutine, so the balancer has
-- calls in progress on every backend at once, while its code for a call reads
-- as a few plain lines.
--
-- No weighting is needed: the fastest backend frees up soonest, so it is
-- chosen most often.
--
-- Shutdown is part of the work: each client calls finished() when done, and
-- once all have, the balancer stops the backends and closes its service.

local threads = require('rascal.threads')

local backends = {
	{ name = 'lookup.fast', milliseconds = 5 },
	{ name = 'lookup.medium', milliseconds = 10 },
	{ name = 'lookup.slow', milliseconds = 20 },
}
local client_count = 4
local lookups_per_client = 30

-- a backend ----------------------------------------------------------------------------------
-- (thread code can be a string of Lua source as well as a function, as here,
-- with its arguments as ...)

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

	function backend:stop()
		service:close()
	end

	service = services.serve(name, 'REP', {
		lookup = 'key:string -> value:string',
		stop = '',
	}, backend)
]==]

-- the balancer -------------------------------------------------------------------------------

local function balancer_thread(backend_names, client_count)
	local prelude = require('prelude')
	local services = require('rascal.services')

	local backends = prelude.list()
	for _, name in ipairs(backend_names) do
		backends:push({
			name = name,
			connection = services.connect(name, 'DEALER'),
			in_progress = 0,
			handled = 0,
		})
	end

	local balancer = {
		clients_finished = 0,
	}
	local service

	function balancer:lookup(key)
		-- the backend with the fewest calls in progress
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

	function balancer:finished()
		self.clients_finished = self.clients_finished + 1
		if self.clients_finished < client_count then
			return
		end
		-- every client is done, so stop the backends and stop serving
		for _, backend in ipairs(backends) do
			log(backend.name .. ' handled ' .. backend.handled .. ' lookups')
			backend.connection:stop()
			backend.connection:close()
		end
		service:close()
	end

	service = services.serve('lookup', 'ROUTER', {
		lookup = 'key:string -> value:string',
		finished = '',
	}, balancer)
end

-- a client -----------------------------------------------------------------------------------

local function client_thread(name, lookups)
	local services = require('rascal.services')

	local lookup = services.connect('lookup')
	for i = 1, lookups do
		lookup:lookup(name .. ' key ' .. i)
	end
	lookup:finished()
	log(name .. ' made ' .. lookups .. ' lookups')
end

-- start the backends, the balancer, then the clients ------------------------------------------

local backend_names = {}
for _, backend in ipairs(backends) do
	threads.start(backend_thread, backend.name, backend.milliseconds)
	backend_names[#backend_names + 1] = backend.name
end
threads.start(balancer_thread, backend_names, client_count)
for i = 1, client_count do
	threads.start(client_thread, 'client ' .. i, lookups_per_client)
end
