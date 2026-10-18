-- test runner
--   rascal tests/run.lua                                runs every test
--   rascal tests/run.lua tests/rascal/database.lua      runs just the given tests
--
-- tests are grouped in folders beside this file:
--   dependencies/   the third party libraries compiled into rascal
--   rascal/         rascal's own libraries
-- and the examples in ../examples are run as tests too.
--
-- dependency and library tests are plain scripts run in this process, and
-- fail if they raise an error. Each example is run in its own rascal process
-- with --test (servers check themselves and exit, rather than serving until
-- stopped), and fails if that process does not exit successfully.

local lfs = require('lfs')

local categories = { 'dependencies', 'rascal', '../examples' }

function expect_equal(actual, expected, message)
	if actual ~= expected then
		error(string.format('%sexpected %s, got %s', message and (message .. ': ') or '',
			tostring(expected), tostring(actual)), 2)
	end
end

-- run this rascal executable with a command line, returning its output
-- (stdout and stderr) with log timestamps removed, and whether it succeeded
local rascal_executable = arg[-1]
function run_rascal(command_line)
	local p = assert(io.popen(rascal_executable .. ' ' .. command_line .. ' 2>&1'))
	local output = p:read('a')
	local success = p:close()
	output = output:gsub('%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d ', '')
	return (output:gsub('%s+$', '')), success == true
end

-- run Lua source as a script in a separate rascal process
function run_rascal_script(source, options)
	local path = os.tmpname()
	local f = assert(io.open(path, 'w'))
	f:write(source)
	f:close()
	local output, success = run_rascal((options or '') .. ' ' .. path)
	os.remove(path)
	return output, success
end

-- find every test, or use those given
local tests_dir = arg[0]:match('^(.*)/[^/]*$') or '.'
local paths = { table.unpack(arg) }
if #paths == 0 then
	for _, category in ipairs(categories) do
		local found = {}
		for name in lfs.dir(tests_dir .. '/' .. category) do
			if name:match('%.lua$') then
				found[#found + 1] = tests_dir .. '/' .. category .. '/' .. name
			end
		end
		table.sort(found)
		table.move(found, 1, #found, #paths + 1, paths)
	end
end

local function run_test(path)
	if path:find('examples/', 1, true) then
		local output, success = run_rascal(path .. ' --test')
		if not success then
			-- the example's own output explains the failure, without a traceback here
			error({ example_output = output })
		end
	else
		dofile(path)
	end
end

local failed = 0
for _, path in ipairs(paths) do
	local name = path:match('([^/]+/[^/]+)%.lua$') or path
	local ok, err = xpcall(run_test, function (err)
		if type(err) == 'table' and err.example_output then
			return 'example failed:\n' .. err.example_output
		end
		return debug.traceback(tostring(err), 2)
	end, path)
	if ok then
		print('  ok    ' .. name)
	else
		failed = failed + 1
		print('  FAIL  ' .. name .. '\n' .. err)
	end
end

print(string.format('%d of %d tests passed', #paths - failed, #paths))
os.exit(failed == 0 and 0 or 1)
