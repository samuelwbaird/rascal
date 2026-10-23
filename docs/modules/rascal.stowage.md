# rascal.stowage

A key value store, backed by SQLite, where each key also has an append-only log and a reverse index. Source: [`lua/rascal/stowage.lua`](../../lua/rascal/stowage.lua).

```lua
local stowage = require('rascal.stowage')
local store = stowage('game.sqlite')

-- a new key, with a generated suffix, an initial value and a reverse index value
local player = store:create_new('player:', { name = 'sam', score = 0 }, { 'name:sam' })

store:set_value(player, { name = 'sam', score = 10 })
store:log_append(player, { event = 'scored', points = 10 })

print(store:reverse_query_one('name:sam'))          -- player:x8Kq2mZa
for _, entry in ipairs(store:log_read(player)) do
	print(entry.id, entry.data.event)
end
```

Each key has:
- **a value:** any value MessagePack can encode, eg. a table, replaced as a whole
- **a log:** a sequence of entries, each appended with an id. Entries are never changed, but can be removed or cleared
- **reverse index values:** strings that each lead back to the key, eg. to find a player by name or email

Every method is an atomic transaction of its own, unless it's called within a larger transaction.

Stowage is built on [rascal.database](rascal.database.md), with its tables in the same SQLite file: `keys`, `log` and `reverse`. As with a database, one thread usually owns a store and serves what others need from it.

## Opening and closing

### stowage(filepath, exclusive)

Opens a store in a database file, creating its tables if needed, or an in memory store if no `filepath` is given.

The file is opened exclusive by default, so no other connection can use it while the store is open. Pass `false` for `exclusive` to share it.

### store:close()

Closes the store's database connection.

### store.db

The store's [database](rascal.database.md) connection, eg. to add tables of your own in the same file.

## Keys

### store:create(key, initial_value, reverse_values)

Creates a key with a known name, eg. `'settings'`, if it doesn't already exist. It returns true if the key was created, or false if it already existed. The initial value and a list of reverse index values are optional.

### store:create_new(prefix, initial_value, reverse_values)

Creates a key that's the prefix followed by a random suffix, eg. `'player:x8Kq2mZa'`, and returns it. The suffix is `stowage.random_suffix_length` characters (8) from `stowage.random_suffix_chars` (letters and digits). It's longer if a key is already taken, so a new key is always unique.

### store:remove(key)

Removes a key, with its value, log and reverse index values.

### store:has_key(key)

True if the key exists. Use this rather than `get_value` to tell a missing key from a key with a nil value.

## Values

### store:get_value(key)

The key's value, or nil if there's no value, or no such key.

### store:set_value(key, value, reverse_values)

Sets the key's value, creating the key if it doesn't exist. With a list of `reverse_values`, it also replaces the key's reverse index values.

Values are encoded with MessagePack, so the same [limits](rascal.messaging.md#values) apply: whole-number floats come back as integers, and an empty table can't be told from an empty array.

## Logs

Each log entry has an `id`, which only increases, across every key in the store, and is never reused, even after entries are removed. So an id can be used to read only what's been added since an earlier read.

### store:log_append(key, data)

Appends an entry to the key's log.

### store:log_read(key, after_id, max)

The key's log entries, oldest first, as a list of `{ id = ..., data = ... }`. With `after_id`, only entries after that id, and with `max`, up to that many.

```lua
local last_id = 0
local entries = store:log_read(key, last_id)
if #entries > 0 then
	last_id = entries[#entries].id
end
```

### store:log_read_reverse(key, count)

The key's log entries, newest first, up to `count` of them if given.

### store:log_clear(key, up_to_id)

Removes the key's log entries, or only those up to and including an id.

### store:log_remove(key, id)

Removes one log entry.

## Reverse index

Reverse index values lead from a string back to keys, eg. from `'email:sam@example.com'` to `'player:x8Kq2mZa'`. A value can lead to more than one key, and a key can have any number of values.

### store:reverse_set(key, reverse_values)

Replaces the key's reverse index values with a list of values.

### store:reverse_remove(key)

Removes all of the key's reverse index values.

### store:reverse_query(value)

A list of the keys a value leads to.

### store:reverse_query_one(value)

The first key a value leads to, or nil.

### store:reverse_first(prefix)

The first reverse index value starting with a prefix, in order, or nil.

## Enumerating keys

Keys are in string order.

| | |
| --- | --- |
| `store:get_keys(prefix)` | a list of every key starting with the prefix |
| `store:remove_keys(prefix)` | removes every key starting with the prefix |
| `store:next_key(prefix, must_match_prefix)` | the first key at or after the prefix, or nil. With `must_match_prefix`, only a key starting with the prefix |
| `store:key_after_key(key)` | the next key after a key, or nil |
| `store:keys_after_key(key, limit)` | a list of the keys after a key, up to an optional limit |
| `store:iterate_keys(prefix)` | an iterator over the keys starting with the prefix |

```lua
for key in store:iterate_keys('player:') do
	print(key, store:get_value(key).score)
end
```

## Transactions

Each method is atomic on its own. To make several changes atomic together, or to make many changes much faster in one commit, group them in a transaction:

```lua
store:transaction(function ()
	store:set_value(from, from_balance - amount)
	store:set_value(to, to_balance + amount)
	store:log_append(from, { sent = amount, to = to })
end)
```

`store:transaction(fn, ...)`, `store:begin_transaction()`, `store:commit_transaction()` and `store:abort_transaction()` work as they do for a [database](rascal.database.md#transactions). Transactions don't nest, but stowage methods called within a transaction become part of it.

For a tick based server, keep a transaction open and commit it periodically with `store:commit_pending()`, which commits only if anything has been written, and `store:has_changes()`. See [db:commit_pending](rascal.database.md#dbcommit_pending).

```lua
store:begin_transaction()
loop:add_interval(250, function ()
	world:tick()
	store:commit_pending()
end)
```
