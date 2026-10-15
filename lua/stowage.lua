-- stowage — a key value store (with sqlite backing), with extended semantics
--
-- :: each database "key" has:
--   an atomic value (this value can be any msgpack encodable value, like a table)
--   a append log, of immutable entries, the log is sequential and can be cleared
--   a reverse index, where any number of values can be associated back to this key
--
-- :: create new entries in the DB two ways, depending whether the entry is named
--    and well known, or not. If not then a new key is automatically assigned.
--    for either method, an initial value and reverse keys, can be optionally assigned when the key is created.
--
--   create('named_entry_called_bob')	-- the entry with this exact key is created if it does not exist
--   create_new('player:')				-- a new entry, with a new key, with the prefix 'player:' is created
--
-- :: entries can be removed from the DB, including all logs and reverse index values
--
--   remove(key)
--
-- :: getting and setting the key value
--
--   has_key
--   get_value
--   set_value
--
-- :: working with the key log
--
--   log_append
--   log_read
--   log_read_reverse
--   log_clear
--   log_remove
--
-- :: working with reverse index
--
--   reverse_set
--   reverse_remove
--   reverse_query
--   reverse_query_one
--   reverse_first
--
-- enumerating the DB
-- export methods, not necessarily suitable for direct network access
--
--   get_keys
--   remove_keys
--   next_key
--   key_after_key
--   keys_after_key
--   iterate_keys
--
-- all method are isolated atomic transactions, unless grouped in a larger transaction
--
--   begin_transaction
--   abort_transaction
--   commit_transaction
--   transaction(fn)

local prelude = require('prelude')
-- sqlite is the backing store
local database = require('database')
-- msgpack is the encoding of values where required
local cmsgpack = require('cmsgpack')

local stowage = prelude.class()

stowage.random_suffix_chars = '1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
stowage.random_suffix_length = 8

-- db_name nil for an in memory store
-- the database is opened exclusive unless exclusive is false
function stowage:init(db_name, exclusive)
	self.db = database(db_name, exclusive ~= false)
	self:prepare_db()
end

function stowage:close()
	self.db:close()
end

-- run fn in a transaction, or as part of the current one if already in a transaction
local function atomic(self, fn)
	if self.db.in_transaction then
		return fn()
	end
	return self.db:transaction(fn)
end

-- the first string after every string that starts with prefix, or nil if there is none
local function prefix_end(prefix)
	local stripped = prefix:gsub('\255+$', '')
	if stripped == '' then
		return nil
	end
	return stripped:sub(1, -2) .. string.char(stripped:byte(-1) + 1)
end

-- create a new key, return true if successful (ie. the key does not already exist)
function stowage:create(key, initial_value, reverse_values)
	return atomic(self, function ()
		if self:has_key(key) then
			return false
		end

		self.db:insert('keys', { key = key, value = database.blob(cmsgpack.pack(initial_value)) })

		if reverse_values then
			for _, value in ipairs(reverse_values) do
				self.db:insert('reverse', { value = value, key = key })
			end
		end

		return true
	end)
end

-- create a new key, using a fixed prefix and a random unique suffix
-- return the new key
function stowage:create_new(prefix, initial_value, reverse_values)
	local random_chars = self.random_suffix_chars
	local length = self.random_suffix_length
	while true do
		local key = { prefix }
		for i = 1, length do
			local index = math.random(1, #random_chars)
			key[#key + 1] = random_chars:sub(index, index)
		end
		key = table.concat(key)
		if self:create(key, initial_value, reverse_values) then
			return key
		end
		length = length + 1
	end
end

-- completely remove a key and all its related values
function stowage:remove(key)
	atomic(self, function ()
		self.db:query('DELETE FROM "keys" WHERE "key" = ?', { key })
		self.db:query('DELETE FROM "log" WHERE "key" = ?', { key })
		self.db:query('DELETE FROM "reverse" WHERE "key" = ?', { key })
	end)
end

-- atomic value per key ------------------------------------------------------------

-- return true if this key exists (get_value returns nil for a missing key or a nil value)
function stowage:has_key(key)
	return self.db:query('SELECT 1 FROM "keys" WHERE "key" = ?', { key }).has_rows
end

-- return the atomic value for this key
function stowage:get_value(key)
	local value = self.db:query('SELECT "value" FROM "keys" WHERE "key" = ?', { key }).value
	return value and cmsgpack.unpack(value)
end

-- set the atomic value for this key (and optionally reset the reverse index)
function stowage:set_value(key, value, reverse_values)
	atomic(self, function ()
		self.db:upsert('keys', { key = key, value = database.blob(cmsgpack.pack(value)) }, { 'key' })

		if reverse_values then
			self:reverse_set(key, reverse_values)
		end
	end)
end

-- sequential log per key ---------------------------------------------------------

function stowage:log_append(key, data)
	assert(key, 'cannot log to nil key')
	self.db:insert('log', { key = key, data = database.blob(cmsgpack.pack(data)) })
end

local function log_entries(result)
	local output = prelude.list()
	for _, row in ipairs(result.rows) do
		output:push({
			id = row.id,
			data = cmsgpack.unpack(row.data),
		})
	end
	return output
end

-- read the log in order, optionally only entries after a log id, and up to a maximum number
function stowage:log_read(key, after_log_id, max)
	return log_entries(self.db:query(
		'SELECT "id", "data" FROM "log" WHERE "key" = ? AND "id" > ? ORDER BY "id" ASC LIMIT ?',
		{ key, after_log_id or 0, max or -1 }
	))
end

-- read the log newest first, optionally up to a maximum number
function stowage:log_read_reverse(key, count)
	return log_entries(self.db:query(
		'SELECT "id", "data" FROM "log" WHERE "key" = ? ORDER BY "id" DESC LIMIT ?',
		{ key, count or -1 }
	))
end

-- clear the log, or only the entries up to and including a log id
function stowage:log_clear(key, up_to_log_id)
	if up_to_log_id then
		self.db:query('DELETE FROM "log" WHERE "key" = ? AND "id" <= ?', { key, up_to_log_id })
	else
		self.db:query('DELETE FROM "log" WHERE "key" = ?', { key })
	end
end

function stowage:log_remove(key, log_id)
	self.db:query('DELETE FROM "log" WHERE "key" = ? AND "id" = ?', { key, log_id })
end

-- reverse index ------------------------------------------------------------------

-- set one or many reverse index values pointing to a key
function stowage:reverse_set(key, reverse_values)
	atomic(self, function ()
		self.db:query('DELETE FROM "reverse" WHERE "key" = ?', { key })
		for _, value in ipairs(reverse_values) do
			self.db:insert('reverse', { value = value, key = key })
		end
	end)
end

-- remove all reverse references to this key
function stowage:reverse_remove(key)
	self.db:query('DELETE FROM "reverse" WHERE "key" = ?', { key })
end

-- retrieve all they keys that are reverse referenced by this value
function stowage:reverse_query(value)
	local keys = prelude.list()
	for _, row in ipairs(self.db:query('SELECT "key" FROM "reverse" WHERE "value" = ?', { value }).rows) do
		keys:push(row.key)
	end
	return keys
end

-- retrieve the first key that matches this reverse reference
function stowage:reverse_query_one(value)
	return self.db:query('SELECT "key" FROM "reverse" WHERE "value" = ? LIMIT 1', { value }).value
end

-- retrieve the first reverse value with this prefix
function stowage:reverse_first(prefix)
	local value = self.db:query('SELECT "value" FROM "reverse" WHERE "value" >= ? ORDER BY "value" LIMIT 1', { prefix }).value
	if value and value:sub(1, #prefix) ~= prefix then
		return nil
	end
	return value
end

-- bulk keys --------------------------------------------------------------------

-- return all keys for a given key prefix
function stowage:get_keys(prefix)
	local upper = prefix_end(prefix)
	local result
	if upper then
		result = self.db:query('SELECT "key" FROM "keys" WHERE "key" >= ? AND "key" < ? ORDER BY "key"', { prefix, upper })
	else
		result = self.db:query('SELECT "key" FROM "keys" ORDER BY "key"')
	end
	local keys = prelude.list()
	for _, row in ipairs(result.rows) do
		keys:push(row.key)
	end
	return keys
end

-- remove all keys for a given key prefix
function stowage:remove_keys(prefix)
	atomic(self, function ()
		for _, key in ipairs(self:get_keys(prefix)) do
			self:remove(key)
		end
	end)
end

-- return the next key that matches or follows a given prefix
function stowage:next_key(prefix, must_match_prefix)
	local key = self.db:query('SELECT "key" FROM "keys" WHERE "key" >= ? ORDER BY "key" LIMIT 1', { prefix }).value
	if must_match_prefix and key and key:sub(1, #prefix) ~= prefix then
		return nil
	end
	return key
end

-- return the next key after a given key
function stowage:key_after_key(key)
	return self.db:query('SELECT "key" FROM "keys" WHERE "key" > ? ORDER BY "key" LIMIT 1', { key }).value
end

-- enumerate keys in bulk
function stowage:keys_after_key(key, limit)
	local output = prelude.list()
	for _, row in ipairs(self.db:query('SELECT "key" FROM "keys" WHERE "key" > ? ORDER BY "key" LIMIT ?', { key, limit or -1 }).rows) do
		output:push(row.key)
	end
	return output
end

-- return a lua iterator over the keys after a prefix, while they match the prefix
function stowage:iterate_keys(prefix)
	local key = prefix

	return function ()
		key = self:key_after_key(key)
		-- end of db
		if not key then
			return nil
		end
		-- prefix no longer matches
		if key:sub(1, #prefix) ~= prefix then
			return nil
		end
		-- otherwise its the next value
		return key
	end
end

-- proxy sqlite transaction support through to this level as its critical to batch commits in practice

function stowage:begin_transaction()
	return self.db:begin_transaction()
end

function stowage:abort_transaction()
	return self.db:abort_transaction()
end

function stowage:commit_transaction()
	return self.db:commit_transaction()
end

function stowage:transaction(fn, ...)
	return self.db:transaction(fn, ...)
end

-- internal, create the tables and indexes if required ---------------------------

function stowage:prepare_db()
	local db = self.db
	-- main key value table, values are msgpack encoded
	db:ensure_table('keys')
	db:ensure_column('keys', 'key', 'TEXT', nil, true)
	db:ensure_column('keys', 'value', 'BLOB')

	-- append mutable events to a log per key, data is msgpack encoded
	-- autoincrement so log ids are never reused, even after the log is cleared
	db:ensure_table('log', true)
	db:ensure_column('log', 'key', 'TEXT')
	db:ensure_column('log', 'data', 'BLOB')
	db:ensure_index('log', { 'key', 'id' })

	-- reverse index from values to keys
	db:ensure_table('reverse')
	db:ensure_column('reverse', 'value', 'TEXT')
	db:ensure_column('reverse', 'key', 'TEXT')
	db:ensure_index('reverse', { 'value', 'key' })
	db:ensure_index('reverse', { 'key' })
end

return stowage
