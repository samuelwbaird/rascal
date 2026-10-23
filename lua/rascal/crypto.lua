-- crypto — hashing, HMAC, encodings and secure random values
--
-- local crypto = require('rascal.crypto')
-- local digest = crypto.hex(crypto.sha256('some data'))
-- local signature = crypto.hmac('sha256', secret, message)
-- local session_id = crypto.random_token(32)
--
-- Digests and HMACs are raw bytes, use crypto.hex or crypto.base64 to make
-- text from them. They are from Mbed TLS (see src/crypto.c). Random values
-- are read from /dev/urandom, so are suitable for secrets such as session
-- ids, tokens and login codes, unlike math.random.

local core = require('rascal.crypto.core')

local crypto = {}

-- digests ----------------------------------------------------------------------------------

function crypto.digest(name, data)
	return core.digest(name, data)
end

function crypto.md5(data) return core.digest('md5', data) end
function crypto.sha1(data) return core.digest('sha1', data) end
function crypto.sha224(data) return core.digest('sha224', data) end
function crypto.sha256(data) return core.digest('sha256', data) end
function crypto.sha384(data) return core.digest('sha384', data) end
function crypto.sha512(data) return core.digest('sha512', data) end

-- the HMAC of data with a key, using a digest by name, eg. 'sha256'
function crypto.hmac(name, key, data)
	return core.hmac(name, key, data)
end

-- encodings --------------------------------------------------------------------------------

-- bytes as lower case hexadecimal text
function crypto.hex(bytes)
	return (bytes:gsub('.', function (c) return string.format('%02x', c:byte()) end))
end

-- bytes from hexadecimal text, or nil if it isn't valid hexadecimal
function crypto.from_hex(text)
	if #text % 2 ~= 0 or text:find('%X') then
		return nil
	end
	return (text:gsub('%x%x', function (pair) return string.char(tonumber(pair, 16)) end))
end

function crypto.base64(bytes)
	return core.base64_encode(bytes)
end

-- bytes from base64 text, or nil if it isn't valid base64
function crypto.from_base64(text)
	return core.base64_decode(text)
end

-- random values ----------------------------------------------------------------------------

function crypto.random_bytes(count)
	return core.random_bytes(count)
end

-- a random integer from min to max inclusive, each equally likely
function crypto.random_int(min, max)
	if math.type(min) ~= 'integer' or math.type(max) ~= 'integer' or max < min then
		error('crypto: random_int needs integers min <= max', 2)
	end
	local range = max - min + 1
	-- 7 bytes is 2^56 possible values, enough for any range used in practice
	local span = 1 << 56
	if range <= 0 or range > span then
		error('crypto: random_int range is too large', 2)
	end
	-- reject values from the incomplete last block of the range, so none is more likely
	local limit = span - span % range
	while true do
		local value = string.unpack('<I7', core.random_bytes(7))
		if value < limit then
			return min + value % range
		end
	end
end

local token_chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

-- a random string of length characters, each chosen equally from chars
-- (default letters and digits), eg. for session ids, tokens or codes
function crypto.random_token(length, chars)
	chars = chars or token_chars
	if #chars < 1 or #chars > 256 then
		error('crypto: random_token needs from 1 to 256 characters to choose from', 2)
	end
	-- reject bytes from the incomplete last block, so no character is more likely
	local limit = 256 - 256 % #chars
	local output = {}
	while #output < length do
		for byte in core.random_bytes(length - #output + 8):gmatch('.') do
			byte = byte:byte()
			if byte < limit and #output < length then
				local index = byte % #chars + 1
				output[#output + 1] = chars:sub(index, index)
			end
		end
	end
	return table.concat(output)
end

-- a random (version 4) UUID, eg. '0b5c4b1e-8f6a-4c1d-9a3e-2f7d6c5b4a39'
function crypto.uuid()
	local bytes = { core.random_bytes(16):byte(1, 16) }
	bytes[7] = (bytes[7] & 0x0f) | 0x40	-- version 4
	bytes[9] = (bytes[9] & 0x3f) | 0x80	-- the RFC 4122 variant
	local hex = crypto.hex(string.char(table.unpack(bytes)))
	return hex:sub(1, 8) .. '-' .. hex:sub(9, 12) .. '-' .. hex:sub(13, 16) .. '-' .. hex:sub(17, 20) .. '-' .. hex:sub(21, 32)
end

return crypto
