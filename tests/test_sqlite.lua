-- lsqlite3 against the compiled in sqlite
local sqlite3 = require('lsqlite3')
local rascal = require('rascal.build')

expect_equal(sqlite3.version(), rascal.dependencies.sqlite)

local db = sqlite3.open_memory()
assert(db:exec([[
	CREATE TABLE item (id INTEGER PRIMARY KEY, name TEXT, data TEXT);
]]) == sqlite3.OK)

local insert = db:prepare('INSERT INTO item (name, data) VALUES (?, ?)')
for i = 1, 10 do
	insert:bind_values('item' .. i, '{"n": ' .. i .. '}')
	assert(insert:step() == sqlite3.DONE)
	insert:reset()
end
insert:finalize()

for count in db:urows('SELECT COUNT(*) FROM item') do
	expect_equal(count, 10)
end
for total in db:urows([[SELECT SUM(json_extract(data, '$.n')) FROM item]]) do
	expect_equal(total, 55)
end

-- compiled in extensions
assert(db:exec([[
	CREATE VIRTUAL TABLE doc USING fts5(body);
	INSERT INTO doc (body) VALUES ('the quick brown fox'), ('lazy dogs sleep');
]]) == sqlite3.OK, db:errmsg())
for match in db:urows([[SELECT body FROM doc WHERE doc MATCH 'fox']]) do
	expect_equal(match, 'the quick brown fox')
end
for value in db:urows('SELECT round(sqrt(16.0))') do
	expect_equal(value, 4.0)
end
db:close()

-- a database on disk
local path = os.tmpname()
local file_db = sqlite3.open(path)
assert(file_db:exec('PRAGMA journal_mode = WAL; CREATE TABLE t (x); INSERT INTO t VALUES (42);') == sqlite3.OK)
file_db:close()
file_db = sqlite3.open(path)
for x in file_db:urows('SELECT x FROM t') do
	expect_equal(x, 42)
end
file_db:close()
os.remove(path)
os.remove(path .. '-wal')
os.remove(path .. '-shm')
