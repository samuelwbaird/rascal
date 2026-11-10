-- crypto — hashing, HMAC, encodings, secure random values, password hashing
-- and encryption
--
-- local crypto = require('rascal.crypto')
-- local digest = crypto.hex(crypto.sha256('some data'))
-- local signature = crypto.hmac('sha256', secret, message)
-- local session_id = crypto.random_token(32)
--
-- local hash = crypto.hash_password(password)       -- store this
-- if crypto.verify_password(hash, attempt) then ... end
--
-- local key = crypto.secret_key()
-- local encrypted = crypto.encrypt(key, 'a secret')
-- local text = crypto.decrypt(key, encrypted)       -- nil if it was changed
--
-- local public_key, secret_key = crypto.key_pair()
-- local sealed = crypto.seal(public_key, 'for the owner of secret_key')
-- local text = crypto.unseal(secret_key, sealed)
--
-- Digests, HMACs, keys and encrypted data are raw bytes, use crypto.hex or
-- crypto.base64 to make text from them. Digests are from Mbed TLS (see
-- src/crypto.c), password hashing and encryption from libsodium (see
-- src/sodium.c). Random values are read from /dev/urandom, so are suitable
-- for secrets such as session ids, tokens and login codes, unlike math.random.

local core = require('rascal.crypto.core')
local sodium = require('rascal.crypto.sodium')

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

-- passwords --------------------------------------------------------------------------------

-- a hash of a password to store, with argon2id. It includes a random salt and
-- its settings, as text, eg. '$argon2id$v=19$m=65536,t=2,p=1$...'.
-- Strength is 'interactive' (the default, using 64MB for a fraction of a second),
-- 'moderate' (256MB) or 'sensitive' (1GB, for several seconds). Hashing holds
-- up its thread, so a busy server can hash in worker threads
function crypto.hash_password(password, strength)
	return sodium.pwhash_str(password, strength)
end

-- does a password match a hash from crypto.hash_password
function crypto.verify_password(hash, password)
	return sodium.pwhash_str_verify(hash, password)
end

-- was a hash made at another strength (or isn't a hash), so should be made
-- again, eg. when the user next logs in with the password
function crypto.password_needs_rehash(hash, strength)
	return sodium.pwhash_str_needs_rehash(hash, strength)
end

-- secret key encryption --------------------------------------------------------------------

-- a random key for crypto.encrypt and crypto.decrypt, 32 bytes
function crypto.secret_key()
	return core.random_bytes(sodium.secret_key_size)
end

-- a message encrypted with a secret key, with XSalsa20 and Poly1305. Each
-- encryption is different, and the result is 40 bytes longer than the message
function crypto.encrypt(key, message)
	return sodium.secretbox(key, message)
end

-- a message from crypto.encrypt, or nil if the key is wrong or the data was changed
function crypto.decrypt(key, data)
	return sodium.secretbox_open(key, data)
end

-- public key encryption --------------------------------------------------------------------

-- a new public key and its secret key, 32 bytes each, for crypto.seal and crypto.unseal
function crypto.key_pair()
	return sodium.box_keypair()
end

-- the public key that belongs with a secret key
function crypto.public_key(secret_key)
	return sodium.box_public_key(secret_key)
end

-- a message sealed with a public key, so only the owner of its secret key can
-- read it. The sender stays anonymous: anyone with the public key can seal
-- messages, so a sealed message says nothing about who sent it. The result is
-- 48 bytes longer than the message
function crypto.seal(public_key, message)
	return sodium.box_seal(public_key, message)
end

-- a message from crypto.seal, or nil if it wasn't sealed for this secret key or was changed
function crypto.unseal(secret_key, data)
	return sodium.box_seal_open(secret_key, data)
end

return crypto
