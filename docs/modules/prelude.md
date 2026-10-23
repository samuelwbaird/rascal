# prelude

A small library of classes, lists and other conveniences, embedded from [`lua/prelude.lua`](../../lua/prelude.lua). Its home is [samuelwbaird/prelude](https://github.com/samuelwbaird/prelude).

[init](init.md) makes everything here global, so `class()` and `list()` can be used directly. Library modules should `require` it instead:

```lua
local prelude = require('prelude')
local Point = prelude.class()
```

## Classes

### prelude.class()

Returns a new class. The class is the metatable of its objects, and calling it constructs an object, passing any arguments to its `init` method.

```lua
local Point = class()

function Point:init(x, y)
	self.x, self.y = x, y
end

function Point:length()
	return math.sqrt(self.x * self.x + self.y * self.y)
end

print(Point(3, 4):length())   -- 5.0
```

Metamethods such as `__tostring` can be defined on the class too.

## Lists

`prelude.list` is a class for tables used as lists. Its methods sit alongside ordinary list operations, so `#`, `ipairs` and indexing work as usual.

### Constructing

| | |
| --- | --- |
| `list()` | a new, empty list |
| `list(table)` | a new list, with a shallow copy of a table's array items |
| `list.wrap(table)` | makes a table into a list in place, without copying |
| `list.pack(...)` | a new list of the arguments |

### Methods

| | |
| --- | --- |
| `list:push(item, ...)` | adds one or more items to the end, returning the first |
| `list:pop()` | removes and returns the last item |
| `list:is_empty()` | true if the list has no items |
| `list:clear()` | removes every item, returning the list |
| `list:clone()` | a new, shallow copy of the list |
| `list:contains(item)` | true if the item is in the list |
| `list:index_of(item)` | the index of the item, or nil |
| `list:remove(index)` | removes the item at an index (or, given a non-number, removes that item), returning the list |
| `list:remove_item(item, more_than_once)` | removes the first occurrence of an item, or every occurrence, returning the list |
| `list:remove_where(predicate)` | removes every item for which `predicate(item)` is true, returning the list |
| `list:select(predicate)` | a new list of the items for which `predicate(item)` is true |
| `list:map(fn)` | a new list of `fn(item)` for each item |
| `list:mutate(fn)` | replaces each item with `fn(item)`, removing those where it returns nil, returning the list |
| `list:with_each(fn)` | calls `fn(item)` for each item |
| `list:random()` | a random item and its index, or nil if the list is empty |
| `list:shuffle()` | shuffles the list in place |
| `list:concat(...)`, `list:insert(...)`, `list:sort(...)`, `list:maxn()` | Lua's `table` functions, as methods |

`tostring(a_list)` gives a bracketed list of its items.

`remove` returns the list, not the removed item, so methods can be chained. To take an item from the front:

```lua
local job = jobs[1]
jobs:remove(1)
```

Taking a random item without replacement:

```lua
local name, index = names:random()
names:remove(index)
```

## Tables

### prelude.weak(keys, values)

A new table with weak references, by default to its values. Pass `true` for `keys` to make the keys weak too, or `false` for `values` to make only the keys weak.

Lua never removes strings or numbers from weak tables, only tables, functions and other objects. So a weak-valued cache of strings never shrinks.

### prelude.readonly(table, deep)

Returns a proxy that reads through to a table, and raises an error when it's written to. With `deep`, tables read from the proxy are also read only, and methods called through it receive the original table as `self`.

### prelude.proxy_chain(object, ...)

Returns a proxy that reads each key from the first of the objects that has it. A method called through the proxy, eg. `proxy:describe()`, receives the object that has it as `self`.

## The global environment

### prelude.global()

Puts everything in the prelude into the globals, returning the prelude. [init](init.md) calls this.

### prelude.strict(including_writes)

Makes reading an undefined global an error. With `including_writes`, defining a new global is an error too. Returns the prelude.

## Code and values

### prelude.sandbox(code, environment, name)

Loads a string of Lua source with `environment` as its globals, returning the function. `name` is used in error messages.

### prelude.serialise(value)

Returns Lua source for a value, which `deserialise` turns back into the value. It handles strings, numbers, booleans and tables of those.

### prelude.deserialise(text)

Runs serialised Lua source in an empty environment, and returns its value. It's not a parser: it runs the code, so only use it on text you trust.

### prelude.pretty(value)

Returns the value as indented, readable Lua source, for logging and debugging.

### prelude.readfile(filename) and prelude.writefile(filename, contents)

Reads a whole file as a string, or writes a string as a whole file, raising an error if the file can't be opened.

### prelude.pcall_trace(fn, ...)

Like `pcall`, but an error comes back with a stack trace.
