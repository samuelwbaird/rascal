-- minimal test runner
--   rascal tests/run.lua                      runs every test_*.lua beside this file
--   rascal tests/run.lua tests/test_zmq.lua   runs just the given test files
-- each test file is a plain script, a test fails if it raises an error

function expect_equal(actual, expected, message)
	if actual ~= expected then
		error(string.format('%sexpected %s, got %s', message and (message .. ': ') or '',
			tostring(expected), tostring(actual)), 2)
	end
end

-- run this rascal executable with a command line, returning its output
-- (stdout and stderr), with log timestamps removed
local rascal_executable = arg[-1]
function run_rascal(command_line)
	local p = assert(io.popen(rascal_executable .. ' ' .. command_line .. ' 2>&1'))
	local output = p:read('a')
	p:close()
	output = output:gsub('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ', '')
	return (output:gsub('%s+$', ''))
end

-- run Lua source as a script in a separate rascal process
function run_rascal_script(source, options)
	local path = os.tmpname()
	local f = assert(io.open(path, 'w'))
	f:write(source)
	f:close()
	local output = run_rascal((options or '') .. ' ' .. path)
	os.remove(path)
	return output
end

local paths = { table.unpack(arg) }
if #paths == 0 then
	local lfs = require('lfs')
	local dir = arg[0]:match('^(.*)/[^/]*$') or '.'
	for name in lfs.dir(dir) do
		if name:match('^test_.*%.lua$') then
			paths[#paths + 1] = dir .. '/' .. name
		end
	end
	table.sort(paths)
end

local failed = 0
for _, path in ipairs(paths) do
	local name = path:match('([^/]+)%.lua$') or path
	local started = os.clock()
	local ok, err = xpcall(dofile, debug.traceback, path)
	if ok then
		print(string.format('  ok    %-20s %.2fs', name, os.clock() - started))
	else
		failed = failed + 1
		print(string.format('  FAIL  %s\n%s', name, err))
	end
end

print(string.format('%d of %d test files passed', #paths - failed, #paths))
os.exit(failed == 0 and 0 or 1)
