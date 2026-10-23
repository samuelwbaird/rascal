-- the embedded stowage key value store
local stowage = require('rascal.stowage')
local prelude = require('prelude')

local db = stowage()

-- create and create_new
assert(db:create('bob', { age = 3 }, { 'name:bob' }))
expect_equal(db:create('bob', { age = 4 }), false, 'existing key is not created again')
expect_equal(db:get_value('bob').age, 3)
local new_key = db:create_new('player:', { score = 0 }, { 'team:red' })
assert(new_key:match('^player:%w%w%w%w%w%w%w%w$'), new_key)
expect_equal(db:get_value('missing'), nil)
assert(db:has_key('bob'))
expect_equal(db:has_key('missing'), false)
db:create('nil_value')
assert(db:has_key('nil_value'), 'a key with a nil value exists')
expect_equal(db:get_value('nil_value'), nil)
expect_equal(db.db:query([[SELECT typeof("value") FROM "keys" WHERE "key" = 'bob']]).value, 'blob')

-- set_value, optionally replacing the reverse index
db:set_value('bob', { age = 5 })
expect_equal(db:get_value('bob').age, 5)
expect_equal(db:reverse_query_one('name:bob'), 'bob')
db:set_value('bob', { age = 6 }, { 'name:robert' })
expect_equal(db:reverse_query_one('name:bob'), nil)
expect_equal(db:reverse_query_one('name:robert'), 'bob')
db:set_value('created_by_set', 'value')
expect_equal(db:get_value('created_by_set'), 'value')

-- log
for i = 1, 5 do
	db:log_append('bob', { n = i })
end
local entries = db:log_read('bob')
expect_equal(#entries, 5)
expect_equal(entries[1].data.n, 1)
expect_equal(#db:log_read('bob', entries[2].id), 3)
expect_equal(#db:log_read('bob', entries[2].id, 2), 2)
expect_equal(#db:log_read('bob', nil, 2), 2, 'a maximum without an after id')
expect_equal(db:log_read_reverse('bob', 2)[1].data.n, 5)
expect_equal(#db:log_read_reverse('bob'), 5, 'reverse without a count')
db:log_remove('bob', entries[1].id)
expect_equal(#db:log_read('bob'), 4)
db:log_clear('bob', entries[3].id)
expect_equal(db:log_read('bob')[1].data.n, 4)

-- log ids are never reused, even when every log entry has been cleared
local last_id = db:log_read('bob')[2].id
db:log_clear('bob')
db:log_append('bob', 'after clear')
assert(db:log_read('bob')[1].id > last_id, 'log id reused after clearing')

-- reverse index
db:reverse_set('bob', { 'colour:blue', 'shape:round' })
db:create('alice', nil, { 'colour:blue' })
local blue = db:reverse_query('colour:blue')
table.sort(blue)
expect_equal(#blue, 2)
expect_equal(blue[1], 'alice')
expect_equal(db:reverse_first('colour:'), 'colour:blue')
expect_equal(db:reverse_first('size:'), nil)
db:reverse_remove('bob')
expect_equal(#db:reverse_query('colour:blue'), 1)

-- keys
for _, name in ipairs({ 'room:a', 'room:b', 'room:c', 'roomy', 'rooms' }) do
	db:create(name)
end
expect_equal(table.concat(db:get_keys('room:'), ','), 'room:a,room:b,room:c')
expect_equal(db:next_key('room:'), 'room:a')
expect_equal(db:next_key('room:z', true), nil)
expect_equal(db:key_after_key('room:a'), 'room:b')
expect_equal(table.concat(db:keys_after_key('room:a', 2), ','), 'room:b,room:c')
local iterated = {}
for key in db:iterate_keys('room:') do
	iterated[#iterated + 1] = key
end
expect_equal(table.concat(iterated, ','), 'room:a,room:b,room:c')
db:remove_keys('room:')
expect_equal(#db:get_keys('room:'), 0)
expect_equal(db:get_value('roomy'), nil)
assert(db:next_key('roomy', true), 'keys outside the prefix are kept')

-- remove takes the value, log and reverse index
db:remove('bob')
expect_equal(db:get_value('bob'), nil)
expect_equal(#db:log_read('bob'), 0)
expect_equal(db:reverse_query_one('name:robert'), nil)

-- transactions group operations, and roll back together
local ok = pcall(db.transaction, db, function ()
	db:create('doomed', 1, { 'doomed:ref' })
	db:log_append('doomed', 'entry')
	error('abort')
end)
assert(not ok)
expect_equal(db:get_value('doomed'), nil)
expect_equal(db:reverse_query_one('doomed:ref'), nil)

-- a transaction kept open to batch writes, as in a tick based server, where
-- stowage methods become part of it and are committed with commit_pending
db:begin_transaction()
expect_equal(db:commit_pending(), false, 'nothing to commit')
db:set_value('ticked', 1)
db:log_append('ticked', 'tick')
expect_equal(db:has_changes(), true)
expect_equal(db:commit_pending(), true)
db:set_value('ticked', 2)
db:abort_transaction()
expect_equal(db:get_value('ticked'), 1, 'the committed tick is kept, the aborted one is not')
expect_equal(#db:log_read('ticked'), 1)

db:close()

-- a smaller version of the old dweeb stowage example: cats patting mice
local path = os.tmpname()
local game = stowage(path)

-- exclusive by default, unless opened with exclusive false
local ok, err = pcall(function () require('rascal.database')(path):has_table('keys') end)
assert(not ok and tostring(err):find('database is locked'), 'stowage is exclusive by default')
local shared_path = os.tmpname()
local shared = stowage(shared_path, false)
local other = require('rascal.database')(shared_path)
assert(other:has_table('keys'), 'not exclusive when opened with exclusive false')
other:close()
shared:close()
os.remove(shared_path)
os.remove(shared_path .. '-wal')
os.remove(shared_path .. '-shm')

local rooms = prelude.list()
for i = 1, 5 do
	rooms:push(game:create_new('room:', { name = 'room' .. i }, { 'room' .. i }))
end
for _, room in ipairs(rooms) do
	for m = 1, 4 do
		game:create_new('mouse:', { room = room, pats = 0, as_at_log_id = 0 }, { 'room:mouse:' .. room })
	end
	game:create_new('cat:', { room = room }, { 'room:cat:' .. room })
end

local total_pats = 0
for iteration = 1, 20 do
	game:transaction(function ()
		for _, room in ipairs(rooms) do
			local mice = game:reverse_query('room:mouse:' .. room)
			for _, cat in ipairs(game:reverse_query('room:cat:' .. room)) do
				game:log_append(mice[math.random(1, #mice)], { event = 'got_patted', cat = cat })
			end
			for _, mouse in ipairs(mice) do
				local data = game:get_value(mouse)
				for _, entry in ipairs(game:log_read(mouse, data.as_at_log_id)) do
					data.pats = data.pats + 1
					data.as_at_log_id = entry.id
				end
				game:set_value(mouse, data)
				game:log_clear(mouse, data.as_at_log_id)
			end
		end
	end)
end
for _, mouse in ipairs(game:get_keys('mouse:')) do
	total_pats = total_pats + game:get_value(mouse).pats
	expect_equal(#game:log_read(mouse), 0)
end
expect_equal(total_pats, 5 * 20, 'every pat was logged and counted once')
game:close()
os.remove(path)
os.remove(path .. '-wal')
