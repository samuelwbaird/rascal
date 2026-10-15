-- database — simple SQLite access, with results read in full
--
-- local db = database.for_filepath('db/app.sqlite')
-- local scratch = database()                    -- in memory
-- local owned = database('db/owned.sqlite', true) -- exclusive to this connection
-- db:ensure_table('item')
-- db:ensure_column('item', 'name', 'TEXT')
-- local id = db:insert('item', { name = 'first' })
-- local result = db:query('SELECT * FROM "item" WHERE "id" = ?', { id })
-- print(result.row.name)
--
-- Prepared statements are cached per SQL string. Every query runs to
-- completion and its rows are collected into the result, so a cached
-- statement is never left part way through and can always be reused.
--
-- Errors raise Lua errors that include SQLite's message and the SQL. Each
-- Lua state (eg. each thread) has its own connections and cache.

local sql = require('lsqlite3')
local prelude = require('prelude')

-- the global log from init, or print when rascal runs with --no-init
local log = rawget(_G, 'log') or print

local database = prelude.class()

-- use in place of nil to set a column to NULL, or to match NULL in a where clause
database.null = setmetatable({}, { __tostring = function () return 'database.null' end })

-- wrap a string value to bind it as a blob rather than text, eg. for binary data
-- blobs are read back as plain strings
local blob_meta = { __tostring = function (blob) return 'database.blob(' .. #blob.value .. ' bytes)' end }
function database.blob(value)
	return setmetatable({ value = value }, blob_meta)
end

-- log each query with the global log function (default for new connections)
database.log_queries = false

-- load shared instance for any given path ----------------------------------------------------

local open_databases = {}

-- exclusive applies when this call opens the database
function database.for_filepath(filepath, exclusive)
	if not open_databases[filepath] then
		open_databases[filepath] = database(filepath, exclusive)
	end
	return open_databases[filepath]
end

-- open a database file, or an in memory database if no filepath is given
-- exclusive keeps the file locked while this connection is open, so no other
-- connection (from any thread or process) can read or write it
function database:init(filepath, exclusive)
	self.filepath = filepath
	if filepath then
		self.filename = filepath:match('([^/]+)$') or filepath
		local sqlite, _, message = sql.open(filepath)
		if not sqlite then
			error('database: unable to open ' .. filepath .. ': ' .. tostring(message))
		end
		self.sqlite = sqlite
	else
		self.filename = ':memory:'
		self.sqlite = sql.open_memory()
	end
	self.prepared = {}
	self.in_transaction = false
	self.log_queries = database.log_queries
	-- set before WAL, so that WAL works without shared memory between connections
	if exclusive then
		self:pragma('locking_mode', 'EXCLUSIVE')
	end
	self:pragma('journal_mode', 'WAL')
end

function database:close()
	if not self.sqlite then
		return
	end
	for _, statement in pairs(self.prepared) do
		statement:finalize()
	end
	self.prepared = {}
	self.sqlite:close()
	self.sqlite = nil
	if self.filepath and open_databases[self.filepath] == self then
		open_databases[self.filepath] = nil
	end
end

-- general purpose SQL query function with bindings ------------------------------------------

-- copy bindings for lsqlite3, with database.null as nil (bound as NULL) and
-- blobs separated out to bind afterwards, and count positional bindings,
-- including any null ones
local function prepare_bindings(bindings)
	local prepared, blobs, positional = {}, nil, 0
	for k, v in pairs(bindings) do
		if math.type(k) == 'integer' and k > positional then
			positional = k
		end
		if getmetatable(v) == blob_meta then
			blobs = blobs or {}
			blobs[k] = v.value
		elseif v ~= database.null then
			prepared[k] = v
		end
	end
	return prepared, blobs, positional
end

-- the parameter index for a positional or named binding
local function parameter_index(statement, parameters, k)
	if math.type(k) == 'integer' then
		return k
	end
	for i = 1, parameters do
		local name = statement:bind_parameter_name(i)
		if name and name:sub(2) == k then
			return i
		end
	end
end

function database:query(query, bindings)
	if not self.sqlite then
		error('database: ' .. self.filename .. ' is closed', 2)
	end
	if self.log_queries then
		log('sql ' .. self.filename, query)
	end
	-- find memoised prepared statement
	local statement = self.prepared[query]
	if not statement then
		statement = self.sqlite:prepare(query)
		if not statement then
			error('database: ' .. self.sqlite:errmsg() .. ' preparing: ' .. query, 2)
		end
		self.prepared[query] = statement
	end
	statement:reset()

	-- every parameter is bound on every call, as a cached statement otherwise
	-- keeps the values from its previous use. bind_names sets any parameter
	-- missing from the bindings to NULL; positional bindings must match the
	-- number of parameters, as a missing one is more likely a mistake
	local parameters = statement:bind_parameter_count()
	if parameters > 0 then
		if not bindings then
			error('database: query expects ' .. parameters .. ' bindings: ' .. query, 2)
		end
		local prepared, blobs, positional = prepare_bindings(bindings)
		if positional > 0 and positional ~= parameters then
			error('database: query expects ' .. parameters .. ' bindings, got ' .. positional .. ': ' .. query, 2)
		end
		if statement:bind_names(prepared) ~= sql.OK then
			error('database: ' .. self.sqlite:errmsg() .. ' binding: ' .. query, 2)
		end
		-- bind_names binds strings as text, so blobs are bound again individually
		if blobs then
			for k, value in pairs(blobs) do
				local index = parameter_index(statement, parameters, k)
				if index and statement:bind_blob(index, value) ~= sql.OK then
					error('database: ' .. self.sqlite:errmsg() .. ' binding: ' .. query, 2)
				end
			end
		end
	elseif bindings and next(bindings) then
		error('database: query has no parameters to bind: ' .. query, 2)
	end

	return self:result(statement, query)
end

-- a wrapper for the results of any query ---------------------------------------------------

function database:result(statement, query)
	local result = {
		success = false,			-- did this query succeed
		row = nil,					-- the first or only row
		value = nil,				-- the first value of the first row (if present)
		has_rows = false,			-- does this query have rows
		num_rows = 0,				-- number of rows
		rows = prelude.list(),		-- all rows in the result
	}

	while true do
		local step = statement:step()
		if step == sql.DONE then
			result.success = true
			break
		elseif step == sql.ROW then
			local row = statement:get_named_values()
			result.rows:push(row)
			if not result.has_rows then
				result.row = row
				result.value = statement:get_value(0)
				result.has_rows = true
			end
			result.num_rows = result.num_rows + 1
		else
			local message = self.sqlite:errmsg()
			statement:reset()
			error('database: ' .. message .. ' in: ' .. (query or '?'), 3)
		end
	end

	return result
end

-- transactions ---------------------------------------------------------------------------

-- transactions do not nest, beginning one while in a transaction is an error

function database:begin_transaction()
	if self.in_transaction then
		error('database: begin_transaction when already in a transaction', 2)
	end
	self:query('BEGIN TRANSACTION')
	self.in_transaction = true
end

function database:commit_transaction()
	if not self.in_transaction then
		error('database: commit_transaction when not in a transaction', 2)
	end
	self:query('COMMIT TRANSACTION')
	self.in_transaction = false
end

function database:abort_transaction()
	if not self.in_transaction then
		error('database: abort_transaction when not in a transaction', 2)
	end
	self.in_transaction = false
	self:query('ROLLBACK TRANSACTION')
end

-- call fn(...) in a transaction, committing if it returns or rolling back and
-- re-raising if it errors, returns the results of fn
function database:transaction(fn, ...)
	self:begin_transaction()
	local results = table.pack(pcall(fn, ...))
	local ok, err = results[1], results[2]
	if ok then
		ok, err = pcall(self.commit_transaction, self)
		if ok then
			return table.unpack(results, 2, results.n)
		end
	end
	-- if the rollback also fails, the original error is the one to report
	pcall(self.abort_transaction, self)
	error(err, 0)
end

-- pragma --------------------------------------------------------------------------------

-- read a pragma, or set it if a value is given, returning the first value of the result
function database:pragma(name, value)
	if value == nil then
		return self:query('PRAGMA ' .. database.safe_name(name)).value
	end
	return self:query('PRAGMA ' .. database.safe_name(name) .. ' = ' .. database.safe_value(value)).value
end

-- convenient versions of basic queries -----------------------------------------------------

function database:select(table, id)
	return self:query('SELECT * FROM ' .. database.safe_name(table, true) .. ' WHERE "id" = ?', { id })
end

function database:select_one(table, where_values)
	return self:select_where(table, where_values, 1)
end

function database:select_where(table, where_values, limit)
	local builder = self:query_builder()
	builder:add('SELECT * FROM')
	builder:add_name(table, true)
	builder:add_where(where_values)
	if limit then
		builder:add('LIMIT ?', { limit })
	end
	return builder:query()
end

function database:select_all(table)
	return self:query('SELECT * FROM ' .. database.safe_name(table, true))
end

-- returns the id of the new row
function database:insert(table, insert_values)
	local builder = self:query_builder()
	builder:add('INSERT INTO')
	builder:add_name(table, true)
	builder:add_names(insert_values, true)
	builder:add('VALUES')
	builder:add_placeholders(insert_values, true)
	builder:query()
	return self.sqlite:last_insert_rowid()
end

-- insert a row, or if it conflicts with an existing row on the conflict
-- columns (default { 'id' }, which must have a primary key or unique index)
-- update that row with the other values instead. Returns the row's id
function database:upsert(table, values, conflict_columns)
	conflict_columns = conflict_columns or { 'id' }
	local is_conflict_column = {}
	for _, column in ipairs(conflict_columns) do
		is_conflict_column[column] = true
	end

	local builder = self:query_builder()
	builder:add('INSERT INTO')
	builder:add_name(table, true)
	builder:add_names(values, true)
	builder:add('VALUES')
	builder:add_placeholders(values, true)
	builder:add('ON CONFLICT')
	builder:add_names(conflict_columns, true)
	local updates = prelude.list()
	for k in pairs(values) do
		if not is_conflict_column[k] then
			updates:push(database.safe_name(k, true) .. ' = excluded.' .. database.safe_name(k, true))
		end
	end
	if #updates > 0 then
		builder:add('DO UPDATE SET ' .. updates:concat(', '))
	else
		builder:add('DO NOTHING')
	end
	builder:add('RETURNING rowid')
	return builder:query().value
end

function database:update(table, id, update_values)
	local builder = self:query_builder()
	builder:add('UPDATE')
	builder:add_name(table, true)
	builder:add_set(update_values)
	builder:add('WHERE "id" = ?', { id })
	return builder:query()
end

function database:update_where(table, update_values, where_values)
	local builder = self:query_builder()
	builder:add('UPDATE')
	builder:add_name(table, true)
	builder:add_set(update_values)
	builder:add_where(where_values)
	return builder:query()
end

function database:delete(table, id)
	return self:query('DELETE FROM ' .. database.safe_name(table, true) .. ' WHERE "id" = ?', { id })
end

function database:delete_where(table, where_values)
	local builder = self:query_builder()
	builder:add('DELETE FROM')
	builder:add_name(table, true)
	builder:add_where(where_values)
	return builder:query()
end

-- create tables and columns ----------------------------------------------------------------

function database:has_table(table)
	return self:query('SELECT "name" FROM "sqlite_master" WHERE "type" = ? AND "name" = ?', { 'table', table }).has_rows
end

function database:has_column(table, column)
	return self:query('SELECT "name" FROM pragma_table_info(?) WHERE "name" = ?', { table, column }).has_rows
end

-- every table has an "id" INTEGER PRIMARY KEY column. With autoincrement,
-- ids are never reused, even after the rows with the highest ids are deleted
-- (it only applies when the table is created)
function database:ensure_table(table, autoincrement)
	if not self:has_table(table) then
		local builder = self:query_builder()
		builder:add('CREATE TABLE')
		builder:add_name(table, true)
		builder:add(autoincrement and '("id" INTEGER PRIMARY KEY AUTOINCREMENT)' or '("id" INTEGER PRIMARY KEY)')
		return builder:query()
	end
end

-- type is SQL written into the statement as given, eg. 'TEXT' or 'INTEGER'
-- a default value (written in as a literal) also makes the column NOT NULL
-- unique adds a unique index on the column, as SQLite cannot add a column
-- with a UNIQUE constraint to an existing table, the effect is the same
function database:ensure_column(table, column, type, default_value, unique)
	if not self:has_column(table, column) then
		local builder = self:query_builder()
		builder:add('ALTER TABLE')
		builder:add_name(table, true)
		builder:add('ADD COLUMN')
		builder:add_name(column, true)
		builder:add(type)
		if default_value ~= nil then
			builder:add('DEFAULT ' .. database.safe_value(default_value))
			builder:add('NOT NULL')
		end
		builder:query()
	end
	if unique then
		self:ensure_index(table, { column }, true)
	end
end

-- creates an index named <table>_index_<column>_<column>...
-- or a unique index named <table>_unique_<column>_<column>...
function database:ensure_index(table, indexed_columns, unique)
	local index_name_parts = prelude.list(indexed_columns)
	index_name_parts:insert(1, unique and 'unique' or 'index')
	index_name_parts:insert(1, table)
	local builder = self:query_builder()
	builder:add(unique and 'CREATE UNIQUE INDEX IF NOT EXISTS' or 'CREATE INDEX IF NOT EXISTS')
	builder:add_name(index_name_parts:concat('_'), true)
	builder:add('ON')
	builder:add_name(table, true)
	builder:add_names(indexed_columns, true)
	return builder:query()
end

-- query building ---------------------------------------------------------------------------

-- a table, column or other name for use in SQL
-- quoted, any name is allowed and is quoted as an SQL identifier, eg. "my table"
-- unquoted, only plain identifiers (letters, digits and _) are allowed
function database.safe_name(name, quote)
	if type(name) ~= 'string' or name == '' or name:find('%z') then
		error('database: invalid name ' .. tostring(name), 2)
	end
	if quote then
		return '"' .. name:gsub('"', '""') .. '"'
	end
	if not name:match('^[%a_][%w_]*$') then
		error('database: invalid unquoted name ' .. name, 2)
	end
	return name
end

-- a value written into SQL as a literal, for where a binding is not possible
function database.safe_value(value)
	if value == nil or value == database.null then
		return 'NULL'
	elseif value == true then
		return '1'
	elseif value == false then
		return '0'
	elseif math.type(value) == 'integer' then
		return string.format('%d', value)
	elseif math.type(value) == 'float' then
		if value ~= value or value == math.huge or value == -math.huge then
			error('database: cannot write ' .. tostring(value) .. ' as an SQL value', 2)
		end
		return string.format('%.17g', value)
	elseif type(value) == 'string' then
		if value:find('%z') then
			error('database: cannot write a string containing zero bytes as an SQL value', 2)
		end
		return "'" .. value:gsub("'", "''") .. "'"
	elseif getmetatable(value) == blob_meta then
		return "X'" .. value.value:gsub('.', function (c) return string.format('%02X', c:byte()) end) .. "'"
	end
	error('database: cannot write a ' .. type(value) .. ' as an SQL value', 2)
end

database.query_builder = prelude.class()

local query_builder = database.query_builder

function query_builder:init(db)
	self.database = db
	self.clauses = prelude.list()
	self.bindings = prelude.list()
end

-- bindings may be a list of values or a table of name = value pairs, in
-- which case the order is that of pairs, and must match any names added
-- from the same table
function query_builder:add(clause, bindings)
	self.clauses:push(clause)
	if bindings then
		if #bindings > 0 then
			for _, value in ipairs(bindings) do
				self.bindings:push(value)
			end
		else
			for k, v in pairs(bindings) do
				self.bindings:push(v)
			end
		end
	end
end

function query_builder:remove_trailing(joiner)
	if self.clauses[#self.clauses] == joiner then
		self.clauses:remove(#self.clauses)
	end
end

function query_builder:add_name(name, wrap)
	self.clauses:push(database.safe_name(name, wrap))
end

function query_builder:add_names(names, wrap)
	local names_to_add = prelude.list()
	if #names > 0 then
		for _, name in ipairs(names) do
			names_to_add:push(database.safe_name(name, wrap))
		end
	else
		for k, v in pairs(names) do
			names_to_add:push(database.safe_name(k, wrap))
		end
	end
	if #names_to_add == 0 then
		error('database: no names given', 3)
	end
	if wrap then
		self.clauses:push('(' .. names_to_add:concat(', ') .. ')')
	else
		self.clauses:push(names_to_add:concat(', '))
	end
end

function query_builder:add_placeholders(bindings, wrap)
	local place_holders_to_add = prelude.list()
	if #bindings > 0 then
		for _, value in ipairs(bindings) do
			place_holders_to_add:push('?')
			self.bindings:push(value)
		end
	else
		for k, v in pairs(bindings) do
			place_holders_to_add:push('?')
			self.bindings:push(v)
		end
	end
	if #place_holders_to_add == 0 then
		error('database: no values given', 3)
	end
	if wrap then
		self.clauses:push('(' .. place_holders_to_add:concat(', ') .. ')')
	else
		self.clauses:push(place_holders_to_add:concat(', '))
	end
end

-- SET "name" = ?, ... from a table of name = value pairs
function query_builder:add_set(update_values)
	if next(update_values) == nil then
		error('database: no values given to update', 3)
	end
	self:add('SET')
	for k, v in pairs(update_values) do
		self:add_name(k, true)
		self:add('= ?', { v })
		self:add(',')
	end
	self:remove_trailing(',')
end

-- WHERE "name" = ? AND ... from a table of name = value pairs
-- a value of database.null matches NULL
function query_builder:add_where(where_values)
	if next(where_values) == nil then
		error('database: no values given for where', 3)
	end
	self:add('WHERE')
	for k, v in pairs(where_values) do
		self:add_name(k, true)
		if v == database.null then
			self:add('IS NULL')
		else
			self:add('= ?', { v })
		end
		self:add('AND')
	end
	self:remove_trailing('AND')
end

function query_builder:query()
	return self.database:query(self.clauses:concat(' '), self.bindings)
end

return database
