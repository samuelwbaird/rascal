-- the init module runs in every Lua state unless rascal is started with --no-init
local rascal = require('rascal.build')
local prelude = require('prelude')

expect_equal(rascal.initialised, true)
expect_equal(package.loaded['init'], true)

-- prelude is published as globals
expect_equal(class, prelude.class)
expect_equal(list, prelude.list)

-- threads run init too
local thread = require('llthreads2').new([[
	return type(class), type(list)
]])
assert(thread:start())
local ok, class_type, list_type = thread:join()
assert(ok, class_type)
expect_equal(class_type, 'function')
expect_equal(list_type, type(prelude.list))

-- run this same executable again with some command line
local rascal_exe = arg[-1]
local function run(command_line)
	local p = assert(io.popen(rascal_exe .. ' ' .. command_line .. ' 2>&1'))
	local output = p:read('a'):gsub('%s+$', '')
	p:close()
	return output
end

expect_equal(run([[-e "print(type(class))"]]), 'function')
expect_equal(run([[--no-init -e "print(type(class), require('rascal.build').initialised)"]]), 'nil\tfalse')
expect_equal(run([[-e "x = 1" --no-init -e "print(x, type(class))"]]), '1\tnil')

-- threads started by a --no-init rascal skip init as well
expect_equal(run([[--no-init -e "local t = require('llthreads2').new('return type(class)') t:start() print(select(2, t:join()))"]]), 'nil')

-- after the script name, --no-init is just an argument to the script
local script = os.tmpname()
local f = assert(io.open(script, 'w'))
f:write('print(arg[1], type(class))')
f:close()
expect_equal(run(script .. ' --no-init'), '--no-init\tfunction')
os.remove(script)

-- init defines a global log function writing to stderr
expect_equal(type(log), 'function')
local logged = run([[-e "log('hello', 42, nil)"]])
assert(logged:match('^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d hello 42 nil$'), logged)
