# rascal.database

Simple SQLite access, with results read in full, and helpers for common queries and for creating tables as they're needed. Source: [`lua/rascal/database.lua`](../../lua/rascal/database.lua).

```lua
local database = require('rascal.database')

local db = database('app.sqlite')
db:ensure_table('item')
db:ensure_column('item', 'name', 'TEXT')

local id = db:insert('item', { name = 'first' })
local result = db:query('SELECT * FROM "item" WHERE "id" = ?', { id })
print(result.row.name)
```

It's built on [lsqlite3](../dependencies.md#lsqlite3), which is also available directly as `require('lsqlite3')`, with the full SQLite build described in [dependencies](../dependencies.md#sqlite).

In rascal, one thread usually owns each database, and serves what other threads need from it as a [service](rascal.services.md). Each Lua state, so each thread, has its own connections. See [Architecture](../technical/architecture.md#threads-own-their-state).

## Opening and closing

### database(filepath, exclusive)

Opens a database file, creating it if needed, or an in memory database if no `filepath` is given. Raises an error if the file can't be opened.

- **Journal mode:** databases are opened in WAL mode.
- **Exclusive:** with `exclusive`, the file stays locked while this connection is open, so no other connection, from any thread or process, can read or write it. Without it, other connections can use the file at the same time, as SQLite allows.

```lua
local db = database('app.sqlite')
local owned = database('owned.sqlite', true)     -- only this connection
local scratch = database()                       -- in memory
```

### database.for_filepath(filepath, exclusive)

Returns the connection already open for a file in this Lua state, or opens one. `exclusive` applies when this call opens it.

### db:close()

Closes the connection. A closed connection raises an error if it's used.

## Queries

### db:query(sql, bindings)

Runs any SQL statement, with its bindings, and returns the result. An error, eg. in the SQL or a constraint, is raised as a Lua error that includes SQLite's message and the SQL.

Bindings are either:
- **a list of values**, for `?` parameters, which must have a value for every parameter
- **a table of names and values**, for `:name` parameters, where a missing name binds NULL

```lua
db:query('SELECT * FROM "item" WHERE "name" = ? AND "size" > ?', { 'first', 10 })
db:query('SELECT * FROM "item" WHERE "name" = :name', { name = 'first' })
```

Every query runs to completion, and its rows are collected into the result. Prepared statements are cached by their SQL, so it's best to use bindings, rather than writing values into SQL.

### Results

| | |
| --- | --- |
| `result.success` | true, as a query that fails raises an error |
| `result.rows` | every row, as a [prelude list](prelude.md#lists) of tables keyed by column name |
| `result.row` | the first row, or nil |
| `result.value` | the first value of the first row, or nil, eg. for `SELECT COUNT(*)` |
| `result.has_rows` | true if there's at least one row |
| `result.num_rows` | the number of rows |

### Values

| Lua | SQLite |
| --- | --- |
| nil, or `database.null` | NULL. Use `database.null` in a table, where nil can't be stored |
| booleans | `1` or `0` |
| integers and floats | INTEGER and REAL |
| strings | TEXT |
| `database.blob(string)` | BLOB, for binary data. Blobs are read back as plain strings |

Values read are nil for NULL, numbers, or strings.

### db.log_queries

Set to true to log each query on this connection. `database.log_queries` sets the default for new connections.

## Transactions

### db:transaction(fn, ...)

Calls `fn(...)` in a transaction. If it returns, the transaction is committed, and `transaction` returns its results. If it raises an error, the transaction is rolled back, and the error raised again.

```lua
db:transaction(function ()
	db:update('account', from, { balance = from_balance - amount })
	db:update('account', to, { balance = to_balance + amount })
end)
```

### db:begin_transaction(), db:commit_transaction(), db:abort_transaction()

The same, as separate steps. Transactions don't nest: beginning one while in a transaction raises an error, as does committing or aborting outside one.

### db:commit_pending()

For a transaction kept open to batch writes, eg. in a tick based game server, where committing every write separately would be slow. If anything has been written since the transaction began, it commits, begins a new transaction straight away, and returns true. Otherwise it does nothing, and returns false. It raises an error outside a transaction.

```lua
db:begin_transaction()
loop:add_interval(250, function ()
	world:tick()                -- any number of writes, all in the open transaction
	db:commit_pending()         -- commits, only if anything was written
end)
```

Writes since the last commit are lost if the process stops, so this trades a little durability for speed. Closing the database doesn't commit an open transaction, so commit it first if its writes should be kept.

### db:has_changes()

True if the open transaction has inserted, updated or deleted any rows, and false outside a transaction. Changes to the schema, eg. creating a table, aren't counted.

## Common queries

Table and column names are quoted, so any name can be used. Values are always bound. Each returns the result of its query, unless noted.

| | |
| --- | --- |
| `db:select(table, id)` | the row with an `id` |
| `db:select_one(table, where)` | the first row matching, eg. `{ name = 'first' }` |
| `db:select_where(table, where, limit)` | the rows matching, up to an optional limit |
| `db:select_all(table)` | every row |
| `db:insert(table, values)` | inserts a row, returning its id |
| `db:upsert(table, values, conflict_columns)` | inserts a row, or updates the row it conflicts with, returning its id |
| `db:update(table, id, values)` | updates the row with an `id` |
| `db:update_where(table, values, where)` | updates the rows matching |
| `db:delete(table, id)` | deletes the row with an `id` |
| `db:delete_where(table, where)` | deletes the rows matching |

A `where` table matches every column given, with `database.null` matching NULL. An empty `where` raises an error, so nothing is updated or deleted by mistake.

`upsert` conflicts on `{ 'id' }` by default, or on the columns given, which need a primary key or unique index. It updates the conflicting row with the values other than the conflict columns.

```lua
db:ensure_column('setting', 'key', 'TEXT', '', true)     -- unique
db:upsert('setting', { key = 'theme', value = 'dark' }, { 'key' })
```

## Creating tables

These create tables, columns and indexes only if they don't exist yet. So a program can call them each time it starts, to create its schema as it's needed, and add to it over time.

### db:ensure_table(table, autoincrement)

Creates a table if it doesn't exist, with an `"id" INTEGER PRIMARY KEY` column, and no others. With `autoincrement`, ids are never reused, even after the rows with the highest ids are deleted. It only applies when the table is created.

### db:ensure_column(table, column, type, default, unique)

Adds a column to a table if it doesn't have one.
- **Type:** SQL, eg. `'TEXT'` or `'INTEGER'`.
- **Default:** a value, which also makes the column NOT NULL.
- **Unique:** adds a unique index on the column.

### db:ensure_index(table, columns, unique)

Creates an index on a list of columns if it doesn't exist, named `<table>_index_<columns>`, or `<table>_unique_<columns>` for a unique index.

### db:has_table(table), db:has_column(table, column)

True if the table, or column, exists.

### db:pragma(name, value)

Reads a pragma, or sets it if a value is given, returning the first value of the result.

## Building SQL

### database.safe_name(name, quote)

A table, column or other name for SQL. With `quote`, any name is allowed, and quoted as an identifier, eg. `"my table"`. Without it, only plain identifiers are allowed, and anything else raises an error.

### database.safe_value(value)

A value written as an SQL literal, for the few places a binding isn't possible, eg. a column default.

### db:query_builder()

A builder for a query made of clauses, collecting the bindings as it goes. This is how the common queries are made.

| | |
| --- | --- |
| `builder:add(clause, bindings)` | adds SQL, with any bindings for it |
| `builder:add_name(name, quote)` | adds a name, see `safe_name` |
| `builder:add_names(names, wrap)` | adds a list of names, or the keys of a table, wrapped in brackets with `wrap` |
| `builder:add_placeholders(values, wrap)` | adds a `?` for each value, binding them |
| `builder:add_set(values)` | `SET "name" = ?, ...` |
| `builder:add_where(where)` | `WHERE "name" = ? AND ...` |
| `builder:query()` | runs the query, returning its result |

```lua
local builder = db:query_builder()
builder:add('SELECT * FROM "item"')
builder:add_where({ owner = owner_id })
builder:add('ORDER BY "name" LIMIT ?', { 20 })
local items = builder:query().rows
```

The names and values of a table are added in the order of `pairs`. That order is the same for the same table, so `add_names` and `add_placeholders` from one table line up.
