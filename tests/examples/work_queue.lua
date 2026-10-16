-- work queue: a queue thread hands out jobs to worker threads
--
--   main thread    serves  work_queue.results (PULL)   collects completed jobs
--                  queues jobs, then says the queue is finished
--   queue thread   serves  work_queue.queue (PULL)     add(job), finish()
--                  serves  work_queue.jobs (REP)       next_job() -> job | nil, status
--                  starts the worker threads
--   worker threads request jobs until there are none, pushing each result to main
--
-- Shutdown is part of the work, there is no general shutdown: a thread
-- waiting on its loop could always be about to receive more work. Here the
-- end of the work flows through the services:
--   main queues every job, then calls finish() on the queue
--   once finished and empty, the queue answers each worker with no job
--   each worker then stops, and once every worker has been told, the queue
--   closes its services, its loop is empty, so it waits for its workers
--   and completes
--   main closes its results service once every result has arrived, and so
--   completes when the queue thread has, and the process exits

local services = require('rascal.services')
local threads = require('rascal.threads')
local messaging = require('rascal.messaging')

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
deadline = messaging.loop():add_once(60000, function ()
	log('timed out with ' .. results.count .. ' of ' .. job_count .. ' jobs completed')
	os.exit(1)
end)

-- the queue thread, which starts the workers -----------------------------------------------

threads.start([==[
	local worker_count = ...
	local services = require('rascal.services')
	local threads = require('rascal.threads')

	local queue = {
		jobs = {},
		first = 1,
		last = 0,
		finished = false,
		workers_stopped = 0,
	}

	local queue_service, jobs_service

	-- queue api, pushed from main

	function queue:add(job)
		self.last = self.last + 1
		self.jobs[self.last] = job
	end

	function queue:finish()
		self.finished = true
	end

	-- jobs api, requested by workers

	function queue:next_job()
		if self.first <= self.last then
			local job = self.jobs[self.first]
			self.jobs[self.first] = nil
			self.first = self.first + 1
			return job
		end
		if not self.finished then
			return nil, 'wait'
		end
		-- finished and empty, this worker stops, and once all have stopped so does the queue
		self.workers_stopped = self.workers_stopped + 1
		if self.workers_stopped == worker_count then
			queue_service:close()
			jobs_service:close()
		end
		return nil, 'finished'
	end

	queue_service = services.serve('work_queue.queue', 'PULL', {
		add = 'job:table',
		finish = '',
	}, queue)

	jobs_service = services.serve('work_queue.jobs', 'REP', {
		next_job = '-> job:table, status:string',
	}, queue)

	-- the workers, each requests jobs until told there are no more
	for i = 1, worker_count do
		threads.start([=[
			local name = ...
			local services = require('rascal.services')
			local messaging = require('rascal.messaging')
			local jobs = services.connect('work_queue.jobs')
			local results = services.connect('work_queue.results')

			while true do
				local job, status = jobs:next_job()
				if job then
					results:completed(name, job.id, job.id * job.id)
				elseif status == 'wait' then
					-- nothing queued yet
					messaging.loop():sleep_ex(5)
				else
					break
				end
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
