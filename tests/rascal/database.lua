-- the embedded database module
local database = require('rascal.database')

local function expect_error(pattern, fn, ...)
	local ok, err = pcall(fn, ...)
	assert(not ok, 'expected an error matching ' .. pattern)
	assert(tostring(err):find(pattern), 'error "' .. tostring(err) .. '" does not match ' .. pattern)
end

local path = os.tmpname()
local function cleanup()
	os.remove(path)
	os.remove(path .. '-wal')
	os.remove(path .. '-shm')
end

local db = database.for_filepath(path)
expect_equal(database.for_filepath(path), db, 'shared instance per path')
expect_equal(db:pragma('journal_mode'), 'wal')

-- schema
db:ensure_table('item')
db:ensure_table('item')
assert(db:has_table('item'))
db:ensure_column('item', 'name', 'TEXT')
db:ensure_column('item', 'score', 'INTEGER', 7)
db:ensure_column('item', 'note', 'TEXT', "it's")
db:ensure_column('item', 'tag', 'TEXT')
assert(db:has_column('item', 'score'))

-- insert and select
local id = db:insert('item', { name = 'first' })
expect_equal(id, 1)
local row = db:select('item', id).row
expect_equal(row.name, 'first')
expect_equal(row.score, 7, 'literal default value')
expect_equal(row.note, "it's", 'quoted literal default value')
expect_equal(db:select_one('item', { name = 'first' }).value, id)
expect_equal(db:select_all('item').num_rows, 1)

-- update and update_where
db:update('item', id, { score = 10 })
expect_equal(db:select('item', id).row.score, 10)
db:insert('item', { name = 'second', score = 10 })
db:update_where('item', { note = 'ten' }, { score = 10 })
expect_equal(db:query('SELECT COUNT(*) FROM "item" WHERE "note" = ?', { 'ten' }).value, 2)

-- null: setting and matching
db:update('item', id, { tag = 'tagged' })
db:update('item', id, { tag = database.null })
expect_equal(db:select('item', id).row.tag, nil)
expect_equal(db:select_where('item', { tag = database.null }).num_rows, 2)
expect_error('NOT NULL constraint failed', db.update, db, 'item', id, { note = database.null })

-- upsert
db:ensure_table('setting')
db:ensure_column('setting', 'key', 'TEXT')
db:ensure_column('setting', 'value', 'TEXT')
db:ensure_index('setting', { 'key' })
db:query('CREATE UNIQUE INDEX IF NOT EXISTS "setting_unique_key" ON "setting" ("key")')
local setting_id = db:upsert('setting', { key = 'colour', value = 'red' }, { 'key' })
expect_equal(db:upsert('setting', { key = 'colour', value = 'blue' }, { 'key' }), setting_id)
expect_equal(db:select('setting', setting_id).row.value, 'blue')
expect_equal(db:select_all('setting').num_rows, 1)
expect_equal(db:upsert('item', { id = id, name = 'renamed' }), id, 'upsert on id by default')
expect_equal(db:select('item', id).row.name, 'renamed')

-- index names include the table, so the same columns can be indexed in two tables
db:ensure_index('item', { 'name' })
db:ensure_table('other')
db:ensure_column('other', 'name', 'TEXT')
db:ensure_index('other', { 'name' })
expect_equal(db:query([[SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('item_index_name', 'other_index_name')]]).value, 2)

-- unique columns and autoincrement ids
db:ensure_table('account', true)
db:ensure_column('account', 'email', 'TEXT', nil, true)
db:ensure_column('account', 'email', 'TEXT', nil, true)
local first_account = db:insert('account', { email = 'a@example.com' })
expect_error('UNIQUE constraint failed', db.insert, db, 'account', { email = 'a@example.com' })
expect_equal(db:upsert('account', { email = 'a@example.com' }, { 'email' }), nil, 'upsert on a unique column')
db:delete('account', first_account)
assert(db:insert('account', { email = 'b@example.com' }) > first_account, 'autoincrement id reused')
db:ensure_index('account', { 'email' }, true)
expect_equal(db:query([[SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'account_unique_email']]).value, 1)

-- blobs
local binary = 'a\0b\255c'
db:ensure_column('item', 'payload', 'BLOB')
local blob_id = db:insert('item', { name = 'blob', payload = database.blob(binary) })
expect_equal(db:query('SELECT typeof("payload") FROM "item" WHERE "id" = ?', { blob_id }).value, 'blob')
expect_equal(db:select('item', blob_id).row.payload, binary)
expect_equal(db:query('SELECT typeof(?)', { database.blob('x') }).value, 'blob')
expect_equal(db:query('SELECT typeof(:b)', { b = database.blob('y') }).value, 'blob')
expect_equal(db:query('SELECT typeof(?) AS t', { 'plain' }).value, 'text')
expect_equal(database.safe_value(database.blob('\0\255')), "X'00FF'")
expect_equal(db:query('SELECT ' .. database.safe_value(database.blob(binary))).value, binary)

-- errors are raised with the message and the SQL
expect_error('no such table', db.query, db, 'SELECT * FROM missing')
db:query('CREATE UNIQUE INDEX IF NOT EXISTS "item_unique_name" ON "item" ("name")')
expect_error('UNIQUE constraint failed.*INSERT INTO', db.insert, db, 'item', { name = 'renamed' })
expect_error('unable to open', database, '/no/such/directory/file.sqlite')

-- statements are rebound on every use, never reusing a previous call's values
expect_equal(db:query('SELECT ? AS v', { 'first' }).value, 'first')
expect_error('expects 1 bindings', db.query, db, 'SELECT ? AS v')
expect_error('expects 2 bindings, got 1', db.query, db, 'SELECT ? AS a, ? AS b', { 1 })
expect_equal(db:query('SELECT :x AS v', { x = 'named' }).value, 'named')
expect_equal(db:query('SELECT :x AS v', { y = 'other' }).value, nil, 'missing named binding is NULL')
expect_error('no parameters', db.query, db, 'SELECT 1', { 1 })

-- empty values are treated as a mistake
expect_error('no values given for where', db.select_where, db, 'item', {})
expect_error('no values given for where', db.delete_where, db, 'item', {})
expect_error('no values given to update', db.update, db, 'item', id, {})
expect_error('no names given', db.insert, db, 'item', {})

-- names and values
expect_equal(database.safe_name('my "odd" table', true), '"my ""odd"" table"')
expect_equal(database.safe_name('plain_name1'), 'plain_name1')
expect_error('invalid unquoted name', database.safe_name, 'not plain')
expect_error('invalid name', database.safe_name, '')
expect_equal(database.safe_value("it's"), "'it''s'")
expect_equal(database.safe_value(3), '3')
expect_equal(database.safe_value(0.5), '0.5')
expect_equal(database.safe_value(true), '1')
expect_equal(database.safe_value(database.null), 'NULL')
expect_error('cannot write', database.safe_value, {})
expect_error('cannot write', database.safe_value, 0 / 0)
expect_equal(db:query('SELECT ' .. database.safe_value("a'b\"c") .. ' AS v').value, "a'b\"c")

-- transactions
local count_items = function () return db:query('SELECT COUNT(*) FROM "item"').value end
local before = count_items()
expect_equal(db:transaction(function (a, b)
	db:insert('item', { name = 'in transaction' })
	return a + b
end, 2, 3), 5)
expect_equal(count_items(), before + 1)

expect_error('deliberate', db.transaction, db, function ()
	db:insert('item', { name = 'rolled back' })
	error('deliberate')
end)
expect_equal(count_items(), before + 1, 'rolled back on error')

-- transactions do not nest
db:transaction(function ()
	expect_error('already in a transaction', db.transaction, db, function () end)
end)

db:begin_transaction()
expect_error('already in a transaction', db.begin_transaction, db)
db:insert('item', { name = 'manual' })
db:abort_transaction()
expect_equal(db:select_one('item', { name = 'manual' }).has_rows, false)

-- a transaction kept open to batch writes, committed only when it has changes
expect_equal(db:has_changes(), false, 'no transaction is open')
expect_error('not in a transaction', db.commit_pending, db)
db:begin_transaction()
expect_equal(db:has_changes(), false)
expect_equal(db:commit_pending(), false, 'nothing to commit')
db:select_all('item')
expect_equal(db:has_changes(), false, 'reading is not a change')
db:insert('item', { name = 'batched' })
expect_equal(db:has_changes(), true)
expect_equal(db:commit_pending(), true)
expect_equal(db.in_transaction, true, 'a new transaction begins after the commit')
expect_equal(db:has_changes(), false)
db:update_where('item', { name = 'batched again' }, { name = 'batched' })
db:abort_transaction()
expect_equal(db:select_one('item', { name = 'batched' }).has_rows, true, 'the committed batch is kept')
expect_equal(db:select_one('item', { name = 'batched again' }).has_rows, false, 'the aborted batch is not')

-- in WAL mode another connection can read while a write transaction is open
local other = database(path)
db:transaction(function ()
	db:insert('item', { name = 'during write' })
	expect_equal(other:select_one('item', { name = 'renamed' }).has_rows, true)
	expect_equal(other:select_one('item', { name = 'during write' }).has_rows, false)
end)
expect_equal(other:select_one('item', { name = 'during write' }).has_rows, true)
other:close()

-- an exclusive connection keeps every other connection out
local exclusive_path = os.tmpname()
local owner = database(exclusive_path, true)
expect_equal(owner:pragma('locking_mode'), 'exclusive')
owner:ensure_table('owned')
expect_error('database is locked', function ()
	database(exclusive_path):has_table('owned')
end)
owner:close()
local after = database(exclusive_path)
assert(after:has_table('owned'), 'available again once the owner closes')
after:close()
os.remove(exclusive_path)
os.remove(exclusive_path .. '-wal')

-- an in memory database
local memory = database()
expect_equal(memory.filename, ':memory:')
memory:ensure_table('scratch')
expect_equal(memory:insert('scratch', { id = 5 }), 5)
memory:close()

-- close
db:close()
db:close()
expect_error('is closed', db.query, db, 'SELECT 1')
assert(database.for_filepath(path) ~= db, 'closed database is removed from the shared instances')
database.for_filepath(path):close()
cleanup()
