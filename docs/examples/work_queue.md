# Work queue

[`examples/work_queue.lua`](../../examples/work_queue.lua): a queue thread hands out jobs to worker threads, which each ask for one job at a time, and send their results back to the main thread.

```bash
rascal examples/work_queue.lua
```

```
queued 10000 jobs
worker 2 completed 4998 jobs
worker 1 completed 5002 jobs
all 10000 jobs completed
```

## What it shows

- **A ROUTER service whose calls wait.** `next_job` parks with `loop:suspend` until there's a job, and `add` wakes it with `loop:resume`. A worker never polls: its call simply returns once there's a job for it.
- **Three kinds of service together.** PULL services for calls that need no reply (adding jobs, reporting results), and a ROUTER service for a call that does.
- **Threads started from a thread.** The queue thread starts the workers, and the worker's code is a function nested inside the queue thread's function.
- **Shutting down as part of the work.** Each thread closes its services once it's done, so every thread's loop has nothing left to do, and the process exits by itself.

```
main thread      serves work_queue.results (PULL)     collects completed jobs
                 queues jobs, then says the queue is finished
queue thread     serves work_queue.queue (PULL)       add(job), finish()
                 serves work_queue.jobs (ROUTER)      next_job() -> job, or nil once finished
                 starts the worker threads
worker threads   ask for one job at a time, until there are none
```

## The source

### Collecting results

[Lines 27–68.](../../examples/work_queue.lua#L27-L68) The main thread serves `work_queue.results`, a PULL service, so workers can report results without waiting for a reply. The target is a plain table with a `completed` method:

```lua
function results:completed(worker, job_id, answer)
	...
	if self.count == job_count then
		...
		results_service:close()
		deadline:reset()
	end
end

results_service = services.serve('work_queue.results', 'PULL', {
	completed = 'worker:string, job_id:number, answer:number',
}, results)
```

Each job's answer is its id squared, so once every job is complete, the total can be checked against the sum of squares. It also checks that no job was completed twice. Either failure exits with an error, which is how the test suite knows the example failed.

Once the last result arrives, the service closes itself, and the deadline timer is stopped. That leaves the main thread with nothing more to do.

### A deadline

[Lines 70–74.](../../examples/work_queue.lua#L70-L74) As this example is also a test, it gives up after a minute rather than waiting forever. `loop` is the global from [init](../modules/init.md). `add_once` returns the timer, which `completed` stops with `deadline:reset()`. A timer that's still active would keep the thread running.

### The queue thread

[Lines 76–89.](../../examples/work_queue.lua#L76-L89) The queue thread is a function, started with `threads.start(queue_thread, worker_count)`. It runs in a new Lua state, so it requires what it uses, and gets `worker_count` as an argument, rather than from the local in the main script.

The queue is a table with a [prelude list](../modules/prelude.md#lists) of jobs.

### Adding jobs

[Lines 91–101.](../../examples/work_queue.lua#L91-L101) `add` and `finish` change the queue, then wake anything waiting on it:

```lua
function queue:add(job)
	self.jobs:push(job)
	loop:resume(self)
end
```

`loop:resume(self)` wakes every coroutine parked against the queue table, straight away. With nothing parked, it does nothing.

### Handing out jobs

[Lines 103–121.](../../examples/work_queue.lua#L103-L121) `next_job` is the heart of the example:

```lua
function queue:next_job()
	while self.jobs:is_empty() and not self.finished do
		loop:suspend(self)
	end
	if not self.jobs:is_empty() then
		local job = self.jobs[1]
		self.jobs:remove(1)
		return job
	end
	...
	return nil
end
```

It's served by a ROUTER service, so each call runs as a coroutine in the queue thread. While there's no job, the call parks against the queue with `loop:suspend(self)`, and other calls carry on meanwhile. Each `add` or `finish` wakes it, and it checks the queue again. Checking again in a loop matters: several workers can be waiting, and only one of them gets each job.

Once the queue is finished and empty, each worker is answered with nil. When every worker has been told, the queue closes both its services, so the queue thread has nothing left to do.

### Serving the queue

[Lines 123–130.](../../examples/work_queue.lua#L123-L130) The same `queue` table is served twice, with a different API and socket type each time: `work_queue.queue` (PULL) for `add` and `finish`, and `work_queue.jobs` (ROUTER) for `next_job`.

```lua
jobs_service = services.serve('work_queue.jobs', 'ROUTER', {
	next_job = '-> job:table',
}, queue)
```

### The workers

[Lines 132–147.](../../examples/work_queue.lua#L132-L147) Each worker connects to the jobs and results services by name, then asks for jobs until there are none:

```lua
local function worker_thread(name)
	local services = require('rascal.services')
	local jobs = services.connect('work_queue.jobs')
	local results = services.connect('work_queue.results')

	local job = jobs:next_job()
	while job do
		results:completed(name, job.id, job.id * job.id)
		job = jobs:next_job()
	end
end
```

The workers connect with REQ, the default, so each `next_job` call blocks the worker until it returns. That suits a worker that does one thing at a time. `results:completed` is a call to a PULL service, so it returns straight away.

`worker_thread` is defined inside `queue_thread`, but it doesn't use any of its locals, so it can be passed to `threads.start`. Once its code is complete, a worker has no sockets in its loop, so it ends.

### Queuing the jobs

[Lines 152–162.](../../examples/work_queue.lua#L152-L162) The main thread connects to the queue, adds every job, and finishes the queue:

```lua
local queue = services.connect('work_queue.queue')
for id = 1, job_count do
	queue:add({ id = id })
end
queue:finish()
```

`services.connect` waits until the queue thread has served `work_queue.queue`, so it doesn't matter which thread gets there first.

The script is then complete. Rather than exiting, the main thread's loop runs until its results service closes and the queue thread completes. Then the process exits.

## See also

- [rascal.services](../modules/rascal.services.md#socket-types) for socket types
- [loop:suspend and loop:resume](../modules/rascal.messaging.md#loopsuspendkey)
- [Load balancer](load_balancer.md), which shares work out by sending it, rather than by workers asking for it
