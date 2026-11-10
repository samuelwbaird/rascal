-- rascal's own command line options (src/main.c), rather than lua.c's
local lfs = require('lfs')
local rascal = require('rascal.build')

-- an absolute path, so that it still runs after a cd
local exe = arg[-1]:sub(1, 1) == '/' and arg[-1] or (lfs.currentdir() .. '/' .. arg[-1])

-- run a shell command line, where $R is this rascal, returning its output
-- (stdout and stderr) and whether it succeeded
local function shell(command_line)
	local p = assert(io.popen(command_line:gsub('%$R', exe) .. ' 2>&1'))
	local output = p:read('a'):gsub('%s+$', '')
	return output, p:close() == true
end

-- versions, help and errors
expect_equal(shell('$R -v'), 'rascal ' .. rascal.version .. ' (' .. rascal.lua_version .. ')')
expect_equal(shell('$R --version'), shell('$R -v'))
local output, success = shell('$R --help')
assert(success and output:find('usage: rascal [options] [script [args]]', 1, true), output)

output, success = shell('$R -e "print(1)"')
expect_equal(output, "rascal: unknown option '-e', see rascal --help")
expect_equal(success, false)
output, success = shell('$R --exec')
expect_equal(output, "rascal: missing a value after '--exec', see rascal --help")
expect_equal(success, false)

-- --exec and --load run in order, then the script with its arguments
local dir = os.tmpname() .. '_dir'
assert(lfs.mkdir(dir))
local function write(name, source)
	local f = assert(io.open(dir .. '/' .. name, 'w'))
	f:write(source)
	f:close()
	return dir .. '/' .. name
end
local loaded = write('loaded.lua', 'order = (order or "") .. "load "')
local script = write('script.lua', 'print(order .. "script", #arg, ...)')
expect_equal(shell('$R --exec "order = \'exec \'" --load ' .. loaded .. ' ' .. script .. ' a --exec < /dev/null'),
	'exec load script\t2\ta\t--exec')

-- an error stops everything after it, and fails
output, success = shell('$R --exec "error(\'stop\')" --exec "print(\'not run\')"')
assert(output:find('^rascal: %(command line%):1: stop\nstack traceback:'), output)
expect_equal(success, false)

-- with nothing to run and stdin not a terminal, stdin is the script
expect_equal(shell('echo "print(\'from stdin\')" | $R'), 'from stdin')
expect_equal(shell('echo "print(...)" | $R - x y'), 'x\ty')
-- --exec alone does not read stdin, --load continues to the prompt
expect_equal(shell('echo "print(\'from stdin\')" | $R --exec "print(1)"'), '1')
output = shell('printf "x = 41\\nx + 1\\nfor i = 1, 2 do\\nprint(i)\\nend\\nerror(\'oops\')\\nprint(\'after\')\\n" | $R --load ' .. loaded)
assert(output:find('^42\n1\n2\nrascal: stdin:1: oops\n.*after$'), output)

-- the work started on the main thread is completed after the prompt
expect_equal(shell('echo "do require(\'rascal.messaging\').loop():add_once(10, function () print(\'completed\') end) end" | $R --load ' .. loaded),
	'completed')

-- module paths: the current directory by default, or each --path
write('local_module.lua', 'return "local module"')
expect_equal(shell('cd ' .. dir .. ' && $R --exec "print((require(\'local_module\')))"'), 'local module')
expect_equal(shell('$R --path ' .. dir .. '/ --exec "print((require(\'local_module\')))"'), 'local module')
expect_equal(shell('$R --path /no/such/dir --path ' .. dir .. ' --exec "print(package.path)"'),
	'/no/such/dir/?.lua;/no/such/dir/?/init.lua;' .. dir .. '/?.lua;' .. dir .. '/?/init.lua')
output = shell('$R --path "a;b" --exec ""')
expect_equal(output, "rascal: --path needs a directory name without ; or ?, not 'a;b', see rascal --help")

-- threads have the same paths
expect_equal(shell('$R --path ' .. dir .. [[ --exec "require('rascal.threads').start(function () print((require('local_module')), package.cpath == '') end)"]]),
	'local module\ttrue')

-- native libraries are only loaded with --allow-libs
expect_equal(shell([[$R --exec "print(package.cpath, #package.searchers, package.loadlib('x', 'y'))"]]),
	'\t3\tnil\tnative libraries are not allowed, start rascal with --allow-libs\tabsent')
output = shell([[$R --allow-libs --exec "print(#package.searchers, package.path:find('/usr/local/', 1, true) ~= nil, package.cpath ~= '')"]])
expect_equal(output, '5\ttrue\ttrue')
expect_equal(shell('$R --allow-libs --path ' .. dir .. ' --exec "print(package.cpath)"'), dir .. '/?.so')

-- embedded modules come first, unless --prefer-files
write('argparse.lua', 'return "file"')
expect_equal(shell('$R --path ' .. dir .. [[ --exec "print(type(require('argparse')))"]]), 'table')
expect_equal(shell('$R --prefer-files --path ' .. dir .. [[ --exec "print((require('argparse')))"]]), 'file')

for name in lfs.dir(dir) do
	if name ~= '.' and name ~= '..' then
		os.remove(dir .. '/' .. name)
	end
end
lfs.rmdir(dir)
os.remove((dir:gsub('_dir$', '')))
