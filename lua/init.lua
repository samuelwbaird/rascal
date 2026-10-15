-- init — runs in every Lua state rascal creates (the main state and
-- each thread) before anything else, unless rascal is started with --no-init
--
-- It runs after the standard libraries and module searchers are set up, but
-- before RASCAL_INIT, -e, -l and the script, and before the global 'arg'
-- table exists. Errors here stop rascal from starting.

require('prelude').global()

-- log(...) writes one timestamped line to stderr, with the arguments
-- converted by tostring and separated by spaces
function log(...)
	local parts = { os.date('%Y-%m-%d %H:%M:%S') }
	for i = 1, select('#', ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	-- a single write, so lines from different threads don't interleave
	io.stderr:write(table.concat(parts, ' ') .. '\n')
end
