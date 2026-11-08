-- compression — gzip for http bodies, and deflate for websocket messages
-- (permessage-deflate, RFC 7692), with zlib through lua-zlib
--
-- Decompressing always has a size limit, as a small compressed body can
-- expand into a very large one. Input is inflated a little at a time, so the
-- limit is noticed before much more than it is held in memory.

local zlib = require('zlib')

local compression = {}

-- compressing smaller bodies and messages than this isn't worth it
compression.min_size = 1024

-- the zlib window sizes for each format
local GZIP = 15 + 16
local RAW = -15

-- inflate with a zlib stream, a chunk of input at a time, returning nil and
-- an error if the output would be larger than max_size
local function inflate(stream, input, max_size)
	local output = {}
	local size = 0
	local chunk = 1024
	for i = 1, #input, chunk do
		local ok, inflated = pcall(stream, input:sub(i, i + chunk - 1))
		if not ok then
			return nil, 'invalid compressed data'
		end
		size = size + #inflated
		if size > max_size then
			return nil, 'too large'
		end
		output[#output + 1] = inflated
	end
	return table.concat(output)
end

-- text compressed with gzip
function compression.gzip(text, level)
	return (zlib.deflate(level or 6, GZIP)(text, 'finish'))
end

-- the text from gzip compressed data, or nil and an error if it isn't valid
-- or would be larger than max_size
function compression.gunzip(data, max_size)
	return inflate(zlib.inflate(GZIP), data, max_size)
end

-- a websocket message compressed for permessage-deflate: raw deflate, with
-- the final empty block (00 00 ff ff) removed, as each message is compressed
-- on its own (no context takeover)
function compression.deflate_message(text)
	local deflated = zlib.deflate(6, RAW)(text, 'sync')
	if deflated:sub(-4) == '\0\0\255\255' then
		deflated = deflated:sub(1, -5)
	end
	return deflated
end

-- the text of a compressed websocket message, or nil and an error
function compression.inflate_message(data, max_size)
	return inflate(zlib.inflate(RAW), data .. '\0\0\255\255', max_size)
end

-- does an accept-encoding header accept gzip
function compression.accepts_gzip(accept_encoding)
	if not accept_encoding then
		return false
	end
	for part in accept_encoding:lower():gmatch('[^,]+') do
		local coding, params = part:match('^%s*([^;%s]+)%s*(.-)%s*$')
		if coding == 'gzip' or coding == '*' then
			local q = params:match('q%s*=%s*([%d%.]+)')
			return not (q and tonumber(q) == 0)
		end
	end
	return false
end

-- content types worth compressing: text, and text based formats
function compression.compressible(content_type)
	if not content_type then
		return false
	end
	content_type = content_type:lower()
	return content_type:find('^text/') ~= nil
		or content_type:find('json') ~= nil
		or content_type:find('javascript') ~= nil
		or content_type:find('xml') ~= nil
end

return compression
