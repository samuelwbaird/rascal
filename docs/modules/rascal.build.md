# rascal.build

What the executable was built with. It's a C module, compiled in from [`src/rascal.c`](../../src/rascal.c).

```lua
local build = require('rascal.build')
print(build.version, build.platform, build.lua_version)   -- 0.1.0  darwin-arm64  Lua 5.4.9
for name, version in pairs(build.dependencies) do
	print(name, version)
end
```

## Fields

| Field | |
| --- | --- |
| `version` | rascal's version, from `VERSION` in the Makefile |
| `platform` | the platform it was built for, eg. `darwin-arm64` or `linux-x86_64-static` |
| `lua_version` | eg. `Lua 5.4.9` |
| `initialised` | false when rascal was started with `--no-init`, see [init](init.md) |
| `dependencies` | a table of each [third party dependency](../dependencies.md) and its version |
| `c_modules` | a list of the compiled in C modules, as they are required |
| `lua_modules` | a list of the embedded Lua modules, as they are required |

## Functions

### build.source(name)

Returns the source of an embedded Lua module, and the path it was embedded from, or nil if there's no such module.

```lua
local source, path = require('rascal.build').source('rascal.http')
print(path, #source)   -- lua/rascal/http.lua  ...
```
