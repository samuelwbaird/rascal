# rascal.crypto

Hashing, HMAC, hex and base64 encodings, and secure random values. Source: [`lua/rascal/crypto.lua`](../../lua/rascal/crypto.lua), over a binding to [Mbed TLS](../dependencies.md#mbed-tls) in [`src/crypto.c`](../../src/crypto.c).

```lua
local crypto = require('rascal.crypto')

local digest = crypto.hex(crypto.sha256('some data'))
local signature = crypto.base64(crypto.hmac('sha256', secret, message))
local session_id = crypto.random_token(32)
```

Use these random values, rather than `math.random`, for anything that must not be guessed: session ids, tokens, login codes, salts or keys.

## Digests

Each returns the digest of a string as raw bytes. Use `crypto.hex` or `crypto.base64` to make text from it.

| | bytes |
| --- | --- |
| `crypto.md5(data)` | 16 |
| `crypto.sha1(data)` | 20 |
| `crypto.sha224(data)` | 28 |
| `crypto.sha256(data)` | 32 |
| `crypto.sha384(data)` | 48 |
| `crypto.sha512(data)` | 64 |
| `crypto.digest(name, data)` | the digest by name, eg. `'sha256'` |

```lua
crypto.hex(crypto.sha256('abc'))    -- 'ba7816bf8f01cfea...', the same as shasum -a 256
```

MD5 and SHA-1 are only for compatibility, eg. checksums or the websocket handshake. Don't use them where security depends on the digest.

Digests aren't suitable for storing passwords, which need a deliberately slow password hash.

### crypto.hmac(name, key, data)

The HMAC of data with a key, using a digest by name, eg. `crypto.hmac('sha256', key, data)`, as raw bytes. An HMAC proves a message was made by someone with the key, eg. to sign a cookie or token.

## Encodings

| | |
| --- | --- |
| `crypto.hex(bytes)` | lower case hexadecimal text |
| `crypto.from_hex(text)` | the bytes, or nil if text isn't valid hexadecimal (either case) |
| `crypto.base64(bytes)` | base64 text, with padding |
| `crypto.from_base64(text)` | the bytes, or nil if text isn't valid base64 |

The decoding functions return nil for invalid input, rather than raising an error, as they're often used on input from clients.

## Random values

Random values are read from `/dev/urandom`, the operating system's secure random source.

### crypto.random_bytes(count)

A string of `count` random bytes.

### crypto.random_int(min, max)

A random integer from `min` to `max` inclusive, each equally likely. Both must be integers, with a range of up to 2^56 values.

### crypto.random_token(length, chars)

A random string of `length` characters, each chosen from `chars`, by default letters and digits. Every character is equally likely.

```lua
crypto.random_token(64)                                   -- a session id
crypto.random_token(8, '2345678abcdefghjkmnpqrstuvwxyz')  -- a login code, without easily confused characters
```

With the default 62 characters, each character gives just under 6 bits, so 22 characters give about 128 bits.

### crypto.uuid()

A random, version 4 UUID, eg. `'0b5c4b1e-8f6a-4c1d-9a3e-2f7d6c5b4a39'`.
