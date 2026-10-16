-- luafilesystem
local lfs = require('lfs')

local dir = os.tmpname()
os.remove(dir)
assert(lfs.mkdir(dir))
expect_equal(lfs.attributes(dir, 'mode'), 'directory')

local f = assert(io.open(dir .. '/file.txt', 'w'))
f:write('hello')
f:close()
expect_equal(lfs.attributes(dir .. '/file.txt', 'size'), 5)

local names = {}
for name in lfs.dir(dir) do
	if name ~= '.' and name ~= '..' then
		names[#names + 1] = name
	end
end
expect_equal(#names, 1)
expect_equal(names[1], 'file.txt')

os.remove(dir .. '/file.txt')
assert(lfs.rmdir(dir))
assert(lfs.currentdir())
