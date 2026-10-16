--[[--
 A general purpose prelude for Lua with no additional dependencies.
 Provide basic classes, lists and other useful meta-functionality.
]]

local prelude = {}

---------------------------------------------------------------------------------------

--- Class meta constructor,
-- creates a new class metatable, which also functions as the constructor for that class,
-- @return A new class metatable/constructor
-- @usage
-- -- add methods to the class metatable as needed
-- -- add an init method to your class to make use of any arguments on construction
-- local NewClass = prelude.class()
-- function NewClass:init(tag)
--   self.tag = tag
-- end
-- function NewClass:announce()
--   print('my tag is ' .. self.tag)
-- end
-- -- now construct objects using our new class
-- local newObj = NewClass('special')
-- newObj:announce()

function prelude.class()
	-- create a class metatable
	local class_meta = {}
	class_meta.__index = class_meta
	-- assign a metatable to the class metatable that allows the class to be used directly as a constructor function
	setmetatable(class_meta, {
		__call = function (class_meta, ...)
			local obj = {}
			setmetatable(obj, class_meta)
			if obj.init then
				obj:init(...)
			end
			return obj
		end,
	})
	-- return the new class for use
	return class_meta
end

---------------------------------------------------------------------------------------

--- List class
-- @section list

prelude.list = prelude.class()

--- List constructor
-- @function list
-- @param clone optionally a single table to (shallow) copy into the new list
-- @return the new list object
-- @usage
-- local empty_list = prelude.list()
-- local cloned_list = prelude.list({ 1, 2, 3 })
function prelude.list:init(clone)
	if clone then
		-- copy from this list
		for i, v in ipairs(clone) do
			self[i] = v
		end
	end
end

--- static method to wrap another table without copying
-- @function wrap
-- @param existing apply the list class as the metable of an existing table without cloning
-- @usage
-- local my_list = list.wrap({ 'existing', 'list' })
function prelude.list.wrap(existing)
	return setmetatable(existing, prelude.list)
end

--- static method to create a list by packing a variable number of arguments
-- @function pack
-- @param ... any number of arguments to pack into the new list
-- @usage
-- local my_list = list.pack(obj1, obj2, obj3)
function prelude.list.pack(...)
	local new_list = prelude.list()
	new_list:push(...)
	return new_list
end

--- Add an item to the end of the list
-- @function list:push
-- @param item the item to add to the list
-- @param ... optionally additional items to add
-- @return The item that was added
-- @usage
-- my_list:push(item)
-- my_list:push(item1, item2, item3, item4)
function prelude.list:push(item, additional, ...)
	self[#self + 1] = item
	if additional then
		self:push(additional, ...)
	end
	return item
end

--- Remove the last item in the list and return it
-- @function list:pop
-- @return The last item in the list
function prelude.list:pop()
	local length = #self
	if length > 0 then
		local value = self[length]
		self[length] = nil
		return value
	end
end

--- Remove the last item in the list and return it
-- @function list:is_empty
-- @return true if the list is empty
function prelude.list:is_empty()
	return next(self) == nil
end

--- Clear all items from the list
-- @function list:clear
-- @return The list for chaining
function prelude.list:clear()
	local length = #self
	while length > 0 do
		self[length] = nil
		length = length - 1
	end
	return self
end

--- Shallow copy a list returning a new list
-- @function list:clone
-- @return The new shallow copy
function prelude.list:clone()
	local new_list = prelude.list()
	for i, v in ipairs(self) do
		new_list[i] = v
	end
	return new_list
end

--- See if the list contains an item
-- @function list:contains
-- @param item The item to look for
-- @return true or false
function prelude.list:contains(item)
	for _, v in ipairs(self) do
		if v == item then
			return true
		end
	end
	return false
end

--- Get the index of an item within the list
-- @function list:index_of
-- @param item The item to look for
-- @return The index of the item or nil
function prelude.list:index_of(item)
	for i, v in ipairs(self) do
		if v == item then
			return i
		end
	end
end

--- Remove one or more occurances of an item
-- @function list:remove_item
-- @param item The item to look for
-- @param more_than_once Whether to remove multiple instances
-- @return The list for chaining
function prelude.list:remove_item(item, more_than_once)
	for i, v in ipairs(self) do
		if v == item then
			table.remove(self, i)
			if not more_than_once then
				return self
			end
		end
	end
	return self
end

--- Remove the item at a given index
-- @function list:remove
-- @param index The index to remove, if not numeric, this will be treated as an item to remove instead
-- @return The list for chaining
function prelude.list:remove(index)
	if type(index) ~= 'number' then
		self:remove_item(index)
	else		
		table.remove(self, index)
	end
	return self
end

--- Remove items matching a predicate function
-- @function list:remove_where
-- @param predicate A function that returns true for any item that should be removed
-- @return The list for chaining
-- @usage
-- my_list:remove_where(function (item)
--   return item.score < 20
-- end)
function prelude.list:remove_where(predicate)
	for _, v in ipairs(self) do
		if predicate(v) then
			table.remove(self, i)
		end
	end
	return self
end

--- Return a new list, only including items that match a predicate
-- @function list:select
-- @param predicate A function that returns true for any item that should be in the new list
-- @return The new list of selected items
-- @usage
-- local high_performers = my_list:select(function (item)
--   return item.score > 100
-- end)
function prelude.list:select(predicate)
	local out = prelude.list()
	for _, v in ipairs(self) do
		if predicate(v) then
			out:push(v)
		end
	end
	return out
end

--- Return a new list, with all items transformed by a given function
-- @function list:map
-- @param fn A function that returns a new value mapped to each item
-- @return The new list of mapped results
function prelude.list:map(fn)
	local out = prelude.list()
	for i, v in ipairs(self) do
		out[i] = fn(v)
	end
	return out
end

--- Destructively update and remove items from the list
-- @function list:mutate
-- @param fn A function that returns a new value, or nil to remove values, for each item in the list
-- @return The list for chaining
function prelude.list:mutate(fn)
	local out = 0
	for i, v in ipairs(self) do
		local updated = fn(v)
		if updated then
			out = out + 1
			self[out] = updated
		end
	end
	local len = #self
	while len > out do
		self[len] = nil
		len = len - 1
	end
	return self
end

--- Call a function with each member of the list
-- @function list:with_each
-- @param fn to call with each member
-- @usage
-- my_list:with_each(function (item)
--   item:update()
-- end)
function prelude.list:with_each(fn)
	for _, v in ipairs(self) do
		fn(v)
	end
end

--- Return a random member of the list, and its index
-- @function list:random
-- @return A random member of the list and its index, or nil if empty
-- @usage
-- local item, index = my_list:random()
-- my_list:remove(index)
function prelude.list:random()
	if #self == 0 then
		return nil
	end
	local index = math.random(#self)
	return self[index], index
end

--- Destructively shuffle the order of the list
-- @function list:shuffle
function prelude.list:shuffle()
    for i = #self, 2, -1 do
      local j = math.random(i)
      self[i], self[j] = self[j], self[i]
    end
end

--- Convert the list to a string when required
-- @function list:__tostring
-- @return A square brackets string representation of the list
function prelude.list:__tostring()
	local strings = {}
    for i, v in ipairs(self) do
		strings[i] = tostring(v)
	end
	return '[' .. table.concat(strings, ', ') .. ']'
end

--- Include Lua table.concat
-- @function list:concat
prelude.list.concat = table.concat
--- Include Lua table.insert
-- @function list:insert
prelude.list.insert = table.insert
--- Include Lua table.maxn
-- @function list:maxn
prelude.list.maxn = table.maxn
--- Include Lua table.sort
-- @function list:sort
prelude.list.sort = table.sort


---------------------------------------------------------------------------------------

--- Meta tables
-- @section meta

--- Return a weak map
-- @param keys Specify if keys are weak (default is false)
-- @param values Specify if values are weak (default is true)
-- @return The new weak map
-- @usage
-- -- create a fully weak map
-- local fully_weak = weak(true)
-- local weak_values = weak()
function prelude.weak(keys, values)
	local mode = ''
	if type(keys) == 'boolean' and keys == true then
		mode = mode .. 'k'
	end
	if type(values) ~= 'boolean' or values == true then
		mode = mode .. 'v'
	end
	return setmetatable({}, {
		__mode = mode
	})
end

-- weak map of read only proxies to reuse
local readonly_proxies = prelude.weak(true, true)

--- Return a read only proxy to another table
-- @param table The Lua table being wrapped by the proxy
-- @param deep Optionally request a deep proxy that wraps referenced objects and method invocations (see test_readonly.lua for details)
-- @return The readonly proxy
function prelude.readonly(table, deep)
	if deep then
		local existing = readonly_proxies[table]
		if existing then
			return existing
		end
		local proxy = {}
		readonly_proxies[table] = proxy
		setmetatable(proxy, {
			__index = function (t, k)
				local value = table[k]
				if type(value) == 'table' then
					return prelude.readonly(value, true)
				elseif type(value) == 'function' then
					-- set a proxy function that will sub "self" when required
					local proxy_function = function (target, ...)
						if target == proxy then
							target = table
						end
						return value(target, ...)
					end
					rawset(proxy, k, proxy_function)
					return proxy_function
				else
					return value
				end
			end,
			__newindex = function (k, v)
				error('cannot update readonly table', 2)
			end,
			__pairs = function () return pairs(table) end,
			__ipairs = function () return ipairs(table) end,
			__len = function () return #table end
		})
		return proxy
	else
		return setmetatable({}, {
			__index = table,
			__newindex = function (k, v)
				error('cannot update readonly table', 2)
			end,
			__pairs = function () return pairs(table) end,
			__ipairs = function () return ipairs(table) end,
			__len = function () return #table end
		})
	end
end


--- Return a proxy to a compound chain of other objects
-- @param obj1 The first object in the chain
-- @param ... Optionally the second object in the chain and so on
-- @return A new proxy
function prelude.proxy_chain(obj1, ...)
	local chain = list.pack(obj1, ...)
	local top_level_proxy = {}
	return setmetatable(top_level_proxy, {
		__index = function (t, k)
			for _, obj in ipairs(chain) do
				local value = obj[k]
				if value then
					return value
				end
				if type(value) == 'function' then
					-- substitute the proxy for the original object in any arguments of the function
					-- set a proxy function that will sub "self" when required
					local proxy_function = function (target, ...)
						if target == top_level_proxy then
							target = obj
						end
						return value(target, ...)
					end
					rawset(top_level_proxy, k, proxy_function)
					return proxy_function
				elseif value then
					return value
				end				
			end
		end,
	})
end

---------------------------------------------------------------------------------------

--- Global environment
-- @section global

--- Optionally make everything in the prelude global
-- @return a reference to the prelude module for chaining
-- @usage
-- require('prelude').global()
-- local my_list = list()
function prelude.global()
	for k, v in pairs(prelude) do
		(_ENV or _G)[k] = v
	end
	-- chain any additional calls
	return prelude
end

--- Optionally prevent uninitialised writes as well
-- @return a reference to the prelude module for chaining
-- @usage
-- local prelude = require('prelude').strict()
-- local test = blah	-- fails due to uninitialised read
function prelude.strict(including_writes)
	setmetatable((_ENV or _G), {
		__index = function (obj, property)
			error('uninitialised read from global ' .. tostring(property), 2)
		end,
		__newindex = (including_writes and function (obj, property, value)
			error('uninitialised write to global ' .. tostring(property), 2)
		end or nil),
	})
	return prelude
end


---------------------------------------------------------------------------------------

--- Utility
-- @section utility

-- private method, encode Lua values as strings into table
function encode_value(value, output, indent, pretty)
	local t = type(value)
	if t == 'string' then
		output[#output + 1] = string.format('%q', value)
	elseif t == 'table' then
		output[#output + 1] = '{'
		if #value > 0 then
			for i, v in ipairs(value) do
				if i > 1 then
					output[#output + 1] = ','
				end
				encode_value(v, output, indent, pretty)
			end
		else
			if pretty then
				indent = indent .. '  '
			end
			local first = true
			for k, v in pairs(value) do
				if pretty then
					output[#output + 1] = '\n'
					output[#output + 1] = indent
				else
					if first then
						first = false
					else
						output[#output + 1] = ','
					end
				end
				if type(k) == 'string' then
					output[#output + 1] = '['
					encode_value(k, output, indent, pretty)
					output[#output + 1] = ']='
					encode_value(v, output, indent, pretty)
				else
					encode_value(k, output, indent, pretty)
					output[#output + 1] = '='
					encode_value(v, output, indent, pretty)
				end
				if pretty then
					output[#output + 1] = ','
				end
			end
			if pretty then
				output[#output + 1] = '\n'
				output[#output + 1] = indent:sub(1, -3)
			end
		end
		output[#output + 1] = '}'
	elseif t == 'boolean' or t == 'number' then
		output[#output + 1] = tostring(value)
	elseif value == nil then
		output[#output + 1] = 'nil'
	elseif pretty then
		output[#output + 1] = '<'
		output[#output + 1] = type(value)
		output[#output + 1] = '>'
	else
		error('serialise unsupported type ' .. t)
	end
end

--- Load code into a simple sandboxed environment
-- @param code The Lua code to load
-- @param environment A table to use as the global environment of the function
-- @param name An optional name, eg. of the source file, to use in error messages loading the code
-- @return The function with the sandboxed environment set
function prelude.sandbox(code, environment, name)
	if rawget(_G, 'setfenv') then
		local fn, message = loadstring(code, name)
		setfenv(fn, environment)
		if not fn then
			error(message)
		end
		return fn
	else
		local fn, message = load(code, name, 't', environment)
		if not fn then
			error(message)
		end
		return fn
	end
end

--- One line read file content
-- @param filename The file name to open and read
-- @return The contents of the file as a string
function prelude.readfile(filename)
	local file = assert(io.open(filename, 'rb'), 'could not read file ' .. filename)
	local contents = file:read('*a')
	file:close()
	return contents
end

--- One line write file content, creating or replacing it
-- @param filename The file name to open and read
-- @param contents The string contents to write to the file
function prelude.writefile(filename, contents)
	local file = assert(io.open(filename, 'wb'), 'could not write to file ' .. filename)
	file:write(contents)
	file:close()
end

--- Serialise a value to a text representation of a Lua table
-- @param value The Lua value to serialise
-- @return A string representation that can be executed as Lua code to return the table
function prelude.serialise(value)
	local output = {'return '}
	encode_value(value, output, '', false)
	return table.concat(output, '')
end

--- Parse Lua values stored	as text into Lua tables
-- - uses the built in Lua parser and IS NOT secure
-- @param string The serialised value to execute and return as a Lua value
-- @return the Lua values
function prelude.deserialise(string)
	-- load the string in an empty sandbox and then execute return the value
	return prelude.sandbox(string, {}, 'deserialise') ()
end

--- Pretty print any Lua table as a Lua code like representation
-- @param value The Lua value to convert to pretty text
-- @return the string representation (multiline with indents)
function prelude.pretty(value)
	local output = {}
	encode_value(value, output, '', true)
	return table.concat(output)
end

--- Alternative to pcall that automatically adds a stack trace to the error
-- @param fn The function to call
-- @param ... and its arguments
function prelude.pcall_trace(fn, ...)
	local debug = require('debug')
	local handle_by_capturing_stack_trace = function (err)
		if debug then
			return debug.traceback(tostring(err), 3)
		else
			return tostring(err)
		end
	end
	return xpcall(function (...) return fn(...) end, handle_by_capturing_stack_trace)
end

return prelude