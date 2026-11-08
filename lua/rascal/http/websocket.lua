-- websocket — the websocket protocol (RFC 6455) for rascal.http: the
-- handshake, frames, and a minimal client. rascal.http uses this for its
-- server, see http.websocket, and the client is for tests and local tools
--
-- local websocket = require('rascal.http.websocket')
-- local socket = websocket.connect('ws://127.0.0.1:8080/live')
-- socket:send({ type = 'hello' })
-- local message = socket:receive(1000)     -- a decoded json message, or nil after 1000ms
-- socket:close()
--
-- Messages are json text, decoded as they're received. Messages can be
-- compressed (permessage-deflate, with no context takeover, so each message
-- is compressed on its own), and binary messages aren't supported.

local cjson = require('cjson')
local crypto = require('rascal.crypto')
local messaging = require('rascal.messaging')
local parser = require('rascal.http.parser')
local compression = require('rascal.http.compression')

local websocket = {}

-- opcodes
websocket.CONTINUATION = 0
websocket.TEXT = 1
websocket.BINARY = 2
websocket.CLOSE = 8
websocket.PING = 9
websocket.PONG = 10

-- close codes
websocket.NORMAL = 1000
websocket.GOING_AWAY = 1001
websocket.PROTOCOL_ERROR = 1002
websocket.UNSUPPORTED = 1003
websocket.NO_STATUS = 1005
websocket.ABNORMAL = 1006
websocket.INVALID_DATA = 1007
websocket.TOO_BIG = 1009
websocket.REPLACED = 4000		-- an application code: replaced by a newer websocket with the same name

local handshake_guid = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

-- the Sec-WebSocket-Accept value for a Sec-WebSocket-Key
function websocket.accept_key(key)
	return crypto.base64(crypto.sha1(key .. handshake_guid))
end

-- is a request a websocket upgrade, returning true, or false and the status to refuse it with
function websocket.check_upgrade(request)
	local headers = request.headers
	if request.method ~= 'GET'
		or not (headers.upgrade or ''):lower():find('websocket', 1, true)
		or not (headers.connection or ''):lower():find('upgrade', 1, true)
		or not headers['sec-websocket-key'] then
		return false, 400
	end
	if headers['sec-websocket-version'] ~= '13' then
		return false, 426
	end
	return true
end

-- xor a payload with a 4 byte mask, 4 bytes at a time
local function apply_mask(payload, mask)
	local key = string.unpack('<I4', mask)
	local out = {}
	local whole = #payload - #payload % 4
	for i = 1, whole, 4 do
		out[#out + 1] = string.pack('<I4', string.unpack('<I4', payload, i) ~ key)
	end
	for i = whole + 1, #payload do
		local index = (i - 1) % 4 + 1
		out[#out + 1] = string.char(payload:byte(i) ~ mask:byte(index))
	end
	return table.concat(out)
end

-- the bytes of one frame, masked with a random key if mask is true (as a
-- client must), and marked as compressed if compressed is true
function websocket.frame(opcode, payload, mask, compressed)
	payload = payload or ''
	local length = #payload
	local mask_bit = mask and 0x80 or 0
	local first = 0x80 | opcode | (compressed and 0x40 or 0)
	local header
	if length < 126 then
		header = string.pack('>BB', first, mask_bit | length)
	elseif length < 0x10000 then
		header = string.pack('>BBI2', first, mask_bit | 126, length)
	else
		header = string.pack('>BBI8', first, mask_bit | 127, length)
	end
	if mask then
		local key = crypto.random_bytes(4)
		return header .. key .. apply_mask(payload, key)
	end
	return header .. payload
end

-- the bytes of a text message, compressed if deflate was negotiated and the
-- message is large enough to be worth it
function websocket.text_frame(text, mask, deflate)
	if deflate and #text >= compression.min_size then
		return websocket.frame(websocket.TEXT, compression.deflate_message(text), mask, true)
	end
	return websocket.frame(websocket.TEXT, text, mask)
end

-- the bytes of a close frame
function websocket.close_frame(code, reason, mask)
	local payload = code and (string.pack('>I2', code) .. (reason or '')) or ''
	return websocket.frame(websocket.CLOSE, payload, mask)
end

-- read one frame from the start of a buffer, returning the frame { fin,
-- opcode, payload, compressed } and the rest of the buffer, or nil if the
-- frame isn't complete yet, or false and a close code if the frame isn't allowed.
-- Frames from clients must be masked (masked = true), frames from servers
-- must not. Frames can be marked compressed only if deflate was negotiated
function websocket.read_frame(buffer, max_size, masked, deflate)
	if #buffer < 2 then
		return nil
	end
	local first, second = buffer:byte(1, 2)
	local fin = first & 0x80 ~= 0
	local opcode = first & 0x0f
	local is_masked = second & 0x80 ~= 0
	local length = second & 0x7f
	local compressed = first & 0x40 ~= 0
	if first & 0x30 ~= 0 or (compressed and not deflate) or is_masked ~= masked then
		-- only compression can be negotiated, and masking must match the sender
		return false, websocket.PROTOCOL_ERROR
	end
	local offset = 3
	if length == 126 then
		if #buffer < 4 then
			return nil
		end
		length = string.unpack('>I2', buffer, 3)
		offset = 5
	elseif length == 127 then
		if #buffer < 10 then
			return nil
		end
		length = string.unpack('>I8', buffer, 3)
		offset = 11
	end
	if opcode >= 8 and (length > 125 or not fin or compressed) then
		-- control frames are short, never fragmented, and never compressed
		return false, websocket.PROTOCOL_ERROR
	end
	if length < 0 or length > max_size then
		return false, websocket.TOO_BIG
	end
	local mask
	if is_masked then
		if #buffer < offset + 3 then
			return nil
		end
		mask = buffer:sub(offset, offset + 3)
		offset = offset + 4
	end
	if #buffer < offset + length - 1 then
		return nil
	end
	local payload = buffer:sub(offset, offset + length - 1)
	if mask then
		payload = apply_mask(payload, mask)
	end
	return { fin = fin, opcode = opcode, payload = payload, compressed = compressed }, buffer:sub(offset + length)
end

-- a reader that assembles frames into messages, calling handlers for each
-- complete text message, close, ping and pong, as the bytes arrive.
-- With deflate, compressed messages are inflated
function websocket.reader(max_size, masked, deflate)
	local buffer = ''
	local fragments = nil
	local fragments_size = 0
	local fragments_compressed = false
	local reader = {}

	-- add bytes, returning a list of events: { 'text', payload }, { 'close', code, reason },
	-- { 'ping', payload }, { 'pong', payload }, or { 'error', close code }, which ends reading
	function reader.add(data)
		buffer = buffer .. data
		local events = {}
		while true do
			local frame, rest = websocket.read_frame(buffer, max_size, masked, deflate)
			if frame == nil then
				break
			elseif frame == false then
				events[#events + 1] = { 'error', rest }
				break
			end
			buffer = rest
			local opcode = frame.opcode
			if opcode == websocket.TEXT or opcode == websocket.BINARY or opcode == websocket.CONTINUATION then
				if opcode == websocket.CONTINUATION and not fragments then
					events[#events + 1] = { 'error', websocket.PROTOCOL_ERROR }
					break
				elseif opcode ~= websocket.CONTINUATION and fragments then
					events[#events + 1] = { 'error', websocket.PROTOCOL_ERROR }
					break
				elseif opcode == websocket.BINARY then
					events[#events + 1] = { 'error', websocket.UNSUPPORTED }
					break
				elseif opcode == websocket.CONTINUATION and frame.compressed then
					-- only the first frame of a message is marked compressed
					events[#events + 1] = { 'error', websocket.PROTOCOL_ERROR }
					break
				end
				if not fragments then
					fragments_compressed = frame.compressed
				end
				fragments = fragments or {}
				fragments[#fragments + 1] = frame.payload
				fragments_size = fragments_size + #frame.payload
				if fragments_size > max_size then
					events[#events + 1] = { 'error', websocket.TOO_BIG }
					break
				end
				if frame.fin then
					local text = table.concat(fragments)
					fragments, fragments_size = nil, 0
					if fragments_compressed then
						local inflated, err = compression.inflate_message(text, max_size)
						if not inflated then
							events[#events + 1] = { 'error', err == 'too large' and websocket.TOO_BIG or websocket.INVALID_DATA }
							break
						end
						text = inflated
					end
					if not utf8.len(text) then
						events[#events + 1] = { 'error', websocket.INVALID_DATA }
						break
					end
					events[#events + 1] = { 'text', text }
				end
			elseif opcode == websocket.CLOSE then
				local code, reason = websocket.NO_STATUS, ''
				if #frame.payload >= 2 then
					code = string.unpack('>I2', frame.payload)
					reason = frame.payload:sub(3)
				end
				events[#events + 1] = { 'close', code, reason }
				break
			elseif opcode == websocket.PING then
				events[#events + 1] = { 'ping', frame.payload }
			elseif opcode == websocket.PONG then
				events[#events + 1] = { 'pong', frame.payload }
			else
				events[#events + 1] = { 'error', websocket.PROTOCOL_ERROR }
				break
			end
		end
		return events
	end

	return reader
end

-- the permessage-deflate offer in a Sec-WebSocket-Extensions header, if
-- there's one this side can accept: each message compressed on its own, with
-- the full window size
function websocket.accepts_deflate(extensions)
	for offer in (extensions or ''):gmatch('[^,]+') do
		local name = offer:match('^%s*([^;%s]+)')
		if name == 'permessage-deflate' then
			local bits = offer:match('server_max_window_bits%s*=%s*"?(%d+)')
			if not bits or tonumber(bits) == 15 then
				return true
			end
		end
	end
	return false
end

-- the extension header accepting deflate, with no context takeover in either direction
websocket.deflate_extension = 'permessage-deflate; server_no_context_takeover; client_no_context_takeover'

-- a json message decoded from text, or nil if it isn't json
function websocket.decode(text)
	local ok, value = pcall(cjson.decode, text)
	if ok then
		return value
	end
end

-- a minimal client -----------------------------------------------------------------------------

local client_class = {}
client_class.__index = client_class

-- connect to a websocket url, eg. ws://127.0.0.1:8080/live, returning the
-- client, or raising an error with the status if the server refuses it.
-- It offers compression unless options.compress is false.
-- It blocks its thread while connecting and receiving, so never connect to
-- a server running in this same thread
function websocket.connect(url, headers, timeout, options)
	local host, port, target = url:match('^ws://([^/:]+):?(%d*)(.*)$')
	if not host then
		error('websocket: connect needs a ws:// url, not ' .. tostring(url), 2)
	end
	port = port ~= '' and port or '80'
	target = target ~= '' and target or '/'
	timeout = timeout or 10000

	local socket = messaging.socket('STREAM')
	socket:set_rcvtimeo(timeout)
	socket:connect('tcp://' .. host .. ':' .. port)
	local frames = socket:recv_all()
	if not frames then
		socket:close()
		error('websocket: could not connect to ' .. url, 2)
	end
	local id = frames[1]

	local key = crypto.base64(crypto.random_bytes(16))
	local lines = {
		'GET ' .. target .. ' HTTP/1.1',
		'host: ' .. host .. ':' .. port,
		'upgrade: websocket',
		'connection: Upgrade',
		'sec-websocket-key: ' .. key,
		'sec-websocket-version: 13',
	}
	if not (options and options.compress == false) then
		lines[#lines + 1] = 'sec-websocket-extensions: ' .. websocket.deflate_extension
	end
	for name, value in pairs(headers or {}) do
		lines[#lines + 1] = name .. ': ' .. value
	end
	socket:send_all({ id, table.concat(lines, '\r\n') .. '\r\n\r\n' })

	-- read the handshake response
	local buffer = ''
	local deflate = false
	while true do
		frames = socket:recv_all()
		if not frames or frames[2] == '' then
			socket:close()
			error('websocket: no handshake from ' .. url, 2)
		end
		buffer = buffer .. frames[2]
		local response, header_length = parser.parse_response(buffer)
		if response == false then
			socket:close()
			error('websocket: invalid handshake from ' .. url, 2)
		elseif response then
			if response.status ~= 101 or response.headers['sec-websocket-accept'] ~= websocket.accept_key(key) then
				socket:close()
				error('websocket: ' .. url .. ' refused with status ' .. response.status, 2)
			end
			buffer = buffer:sub(header_length + 1)
			deflate = (response.headers['sec-websocket-extensions'] or ''):find('permessage-deflate', 1, true) ~= nil
			break
		end
	end

	local client = setmetatable({
		socket = socket,
		id = id,
		deflate = deflate,
		reader = websocket.reader(16 * 1024 * 1024, false, deflate),
		messages = {},
		closed = nil,
	}, client_class)
	if buffer ~= '' then
		client:handle(client.reader.add(buffer))
	end
	return client
end

function client_class:handle(events)
	for _, event in ipairs(events) do
		if event[1] == 'text' then
			self.messages[#self.messages + 1] = websocket.decode(event[2])
		elseif event[1] == 'ping' then
			self.socket:send_all({ self.id, websocket.frame(websocket.PONG, event[2], true) })
		elseif event[1] == 'close' then
			self.closed = { code = event[2], reason = event[3] }
		elseif event[1] == 'error' then
			self.closed = { code = event[2], reason = '' }
		end
	end
end

-- send a message, a table encoded as json, or a string of json
function client_class:send(message)
	if type(message) ~= 'string' then
		message = cjson.encode(message)
	end
	self.socket:send_all({ self.id, websocket.text_frame(message, true, self.deflate) })
end

-- send a frame as it is, eg. a ping, for tests
function client_class:send_frame(opcode, payload)
	self.socket:send_all({ self.id, websocket.frame(opcode, payload, true) })
end

-- the next message, waiting up to timeout milliseconds, or nil if none
-- arrives or the websocket closes (see client.closed for its code and reason)
function client_class:receive(timeout)
	local finish = messaging.utc_time() + (timeout or 10000) / 1000
	while #self.messages == 0 and not self.closed do
		local remaining = math.floor((finish - messaging.utc_time()) * 1000)
		if remaining <= 0 then
			return nil
		end
		self.socket:set_rcvtimeo(remaining)
		local frames = self.socket:recv_all()
		if frames then
			if frames[2] == '' then
				self.closed = self.closed or { code = websocket.ABNORMAL, reason = '' }
			else
				self:handle(self.reader.add(frames[2]))
			end
		end
	end
	return table.remove(self.messages, 1)
end

-- close the websocket, with an optional code and reason, waiting up to a
-- second for the server to answer the close before disconnecting
function client_class:close(code, reason)
	if self.socket then
		if not self.closed then
			self.socket:send_all({ self.id, websocket.close_frame(code or websocket.NORMAL, reason, true) })
			local finish = messaging.utc_time() + 1
			while not self.closed and messaging.utc_time() < finish do
				self:receive(math.max(1, math.floor((finish - messaging.utc_time()) * 1000)))
			end
		end
		self.socket:send_all({ self.id, '' })
		self.socket:close()
		self.socket = nil
	end
end

return websocket
