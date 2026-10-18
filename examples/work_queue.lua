-- work queue: a queue thread hands out jobs to worker threads
--
--   main thread    serves  work_queue.results (PULL)    collects completed jobs
--                  queues jobs, then says the queue is finished
--   queue thread   serves  work_queue.queue (PULL)      add(job), finish()
--                  serves  work_queue.jobs (ROUTER)     next_job() -> job, or nil once finished
--                  starts the worker threads
--   worker threads ask for one job at a time, until there are none
--
-- next_job is called on a ROUTER service, so each call runs as a coroutine in
-- the queue thread. When there is no job yet it parks with loop:suspend, and
-- each add (or finish) resumes the parked calls, which check the queue again.
-- A worker never polls, its call simply returns once there is a job for it.
--
-- Shutdown is part of the work: main queues every job then calls finish().
-- Once finished and empty, the queue answers each request with no job, and
-- once every worker has been told, it closes its services. Main
-- closes its results service once every result has arrived, then every
-- thread is complete and the process exits.

local services = require('rascal.services')
local threads = require('rascal.threads')

local job_count = 10000
local worker_count = 2

-- collect results in the main thread -------------------------------------------------------

local results = {
	count = 0,
	total = 0,
	seen = {},
	by_worker = {},
}

local results_service
local deadline

function results:completed(worker, job_id, answer)
	if self.seen[job_id] then
		log('job ' .. job_id .. ' was completed twice')
		os.exit(1)
	end
	self.seen[job_id] = true
	self.count = self.count + 1
	self.total = self.total + answer
	self.by_worker[worker] = (self.by_worker[worker] or 0) + 1

	if self.count == job_count then
		-- each job squares its id, so the total is the sum of squares
		local expected = job_count * (job_count + 1) * (2 * job_count + 1) // 6
		if self.total ~= expected then
			log('expected a total of ' .. expected .. ', got ' .. self.total)
			os.exit(1)
		end
		for worker, count in pairs(self.by_worker) do
			log(worker .. ' completed ' .. count .. ' jobs')
		end
		log('all ' .. job_count .. ' jobs completed')
		-- all done, so nothing more to wait for in this thread
		results_service:close()
		deadline:reset()
	end
end

results_service = services.serve('work_queue.results', 'PULL', {
	completed = 'worker:string, job_id:number, answer:number',
}, results)

-- as this is also a test, give up if it takes too long
deadline = loop:add_once(60000, function ()
	log('timed out with ' .. results.count .. ' of ' .. job_count .. ' jobs completed')
	os.exit(1)
end)

-- the queue thread, which starts the workers -----------------------------------------------

threads.start([==[
	local worker_count = ...
	local prelude = require('prelude')
	local services = require('rascal.services')
	local threads = require('rascal.threads')

	local queue = {
		jobs = prelude.list(),
		finished = false,
		workers_stopped = 0,
	}

	local queue_service, jobs_service

	-- queue api, pushed from main, each change wakes any calls waiting for a job

	function queue:add(job)
		self.jobs:push(job)
		loop:resume(self)
	end

	function queue:finish()
		self.finished = true
		loop:resume(self)
	end

	-- jobs api, requested by the workers, each call waits until there is a job or the queue is finished

	function queue:next_job()
		while self.jobs:is_empty() and not self.finished do
			loop:suspend(self)
		end
		if not self.jobs:is_empty() then
			local job = self.jobs[1]
			self.jobs:remove(1)
			return job
		end
		-- finished and empty, so this worker stops, and once all have stopped so does the queue
		self.workers_stopped = self.workers_stopped + 1
		if self.workers_stopped == worker_count then
			queue_service:close()
			jobs_service:close()
		end
		return nil
	end

	queue_service = services.serve('work_queue.queue', 'PULL', {
		add = 'job:table',
		finish = '',
	}, queue)

	jobs_service = services.serve('work_queue.jobs', 'ROUTER', {
		next_job = '-> job:table',
	}, queue)

	-- the workers, each asking for one job at a time until there are no more
	for i = 1, worker_count do
		threads.start([=[
			local name = ...
			local services = require('rascal.services')
			local jobs = services.connect('work_queue.jobs')
			local results = services.connect('work_queue.results')

			local job = jobs:next_job()
			while job do
				results:completed(name, job.id, job.id * job.id)
				job = jobs:next_job()
			end
		]=], 'worker ' .. i)
	end
]==], worker_count)

-- queue the jobs ---------------------------------------------------------------------------

local queue = services.connect('work_queue.queue')
for id = 1, job_count do
	queue:add({ id = id })
end
queue:finish()
log('queued ' .. job_count .. ' jobs')

-- the script is complete, this thread's loop now runs until results_service
-- closes and the queue thread completes
