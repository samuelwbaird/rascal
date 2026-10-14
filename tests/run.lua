-- minimal test runner: rascal tests/run.lua tests/test_*.lua
-- each test file is a plain script, a test fails if it raises an error

function expect_equal(actual, expected, message)
	if actual ~= expected then
		error(string.format('%sexpected %s, got %s', message and (message .. ': ') or '',
			tostring(expected), tostring(actual)), 2)
	end
end

local failed = 0
for _, path in ipairs(arg) do
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

print(string.format('%d of %d test files passed', #arg - failed, #arg))
os.exit(failed == 0 and 0 or 1)
