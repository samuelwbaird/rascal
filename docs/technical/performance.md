# Performance

Notes on how rascal performs, and how to measure it.

## Load testing HTTP

[`examples/http_server.lua`](../../examples/http_server.lua) is set up for load testing, with routes handled in the server thread, in worker threads, and as static files. See [its guide](../examples/http_server.md). With [wrk](https://github.com/wg/wrk):

```bash
rascal examples/http_server.lua 8080 4                        # port, worker threads

wrk -t4 -c64 -d10s http://127.0.0.1:8080/hello                # handled in the server thread
wrk -t4 -c64 -d10s http://127.0.0.1:8080/workers/hello        # handled in worker threads
wrk -t4 -c256 -d10s http://127.0.0.1:8080/workers/slow        # each request waits 20ms in a worker
wrk -t4 -c64 -d10s http://127.0.0.1:8080/                     # a static file
```

### Results

In a 2 CPU Linux container, shared with wrk, the server handled:

| | requests a second |
| --- | --- |
| handled in the server thread | about 60,000 |
| static files | about 45,000 |
| through worker threads | about 22,000 |

None of these runs had errors.

Some things these show:
- **Fast handlers belong in the server thread.** Handing a request to a worker thread and back costs more than a simple handler does. Workers pay off for handlers that are slow, or use the CPU, which would otherwise hold up every other request in the server thread.
- **Waiting is cheap.** A handler that waits, eg. `/workers/slow`, holds only its own coroutine. Many requests can be waiting at once, in a few threads.
- **Static files** can be kept in memory with `http.static(directory, { cache_seconds = n })`, rather than read for each request.

## Measure on Linux

On macOS, each hand-off between ZeroMQ's I/O thread and rascal's threads is a slow kernel wake-up. That limits a single server to about 8,000 requests a second, however many connections there are.

This is a limitation of the platform, not of rascal: the same server on the same machine, in a Linux container, handles many times as many requests. So measure performance on Linux, ideally on the hardware a server will run on.

## Where time goes

- **Messages between threads** are packed with MessagePack, sent over inproc sockets, and unpacked, so each service call costs a little more than its arguments' size. Calls that pass large values, or many small calls in a loop, are worth batching into fewer calls.
- **SQLite queries** use cached prepared statements, see [rascal.database](../modules/rascal.database.md#dbquerysql-bindings). Grouping many writes in one transaction is much faster than committing each.
- **One thread per resource** handles calls one at a time. When a service becomes a bottleneck, it can be split by key across several threads, or its reads served from copies kept in other threads, as in the [shared_cache](../examples/shared_cache.md) example. Stateless work can be spread with `services.serve_balanced`.
