# rascal.crypto

Hashing, HMAC, hex and base64 encodings, secure random values, password hashing, and encryption. Source: [`lua/rascal/crypto.lua`](../../lua/rascal/crypto.lua), over bindings to [Mbed TLS](../dependencies.md#mbed-tls) in [`src/crypto.c`](../../src/crypto.c), and to [libsodium](../dependencies.md#libsodium) in [`src/sodium.c`](../../src/sodium.c).

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

Digests aren't suitable for storing passwords, which need a deliberately slow password hash: see [passwords](#passwords).

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

## Passwords

Passwords are hashed with argon2id, which is deliberately slow and uses a lot of memory, so guessing passwords from a stolen hash is expensive.

```lua
-- when the password is set, store the hash
user.password_hash = crypto.hash_password(password)

-- when logging in
if crypto.verify_password(user.password_hash, attempt) then
	if crypto.password_needs_rehash(user.password_hash) then
		user.password_hash = crypto.hash_password(attempt)
	end
	...
end
```

| | |
| --- | --- |
| `crypto.hash_password(password, strength)` | a hash to store, as text, eg. `'$argon2id$v=19$m=65536,t=2,p=1$...'`. It includes a random salt and its settings |
| `crypto.verify_password(hash, password)` | whether the password matches the hash. False for anything that isn't a hash |
| `crypto.password_needs_rehash(hash, strength)` | whether the hash was made at another strength (or isn't a hash), so should be made again when the password is next known, eg. at login |

Strength is one of:

| | |
| --- | --- |
| `'interactive'` | the default, for logins: 64MB, and a fraction of a second |
| `'moderate'` | 256MB, and about a second |
| `'sensitive'` | 1GB, and several seconds, eg. for keys that rarely change |

Hashing holds up its thread for that long, like any other work. A server handling many logins can hash in [worker threads](rascal.http.md#httpworkerscount-build-).

## Encryption

Keys and encrypted data are raw bytes, like digests. Use `crypto.base64` or `crypto.hex` to store or send them as text. Decrypting returns nil, rather than raising an error, when the key is wrong or the data was changed, as encrypted data often comes from clients.

### With a secret key

The same key encrypts and decrypts, eg. to keep data in a cookie or a file that only the server can read.

```lua
local key = crypto.secret_key()                 -- keep this secret, eg. in the server's configuration
local encrypted = crypto.encrypt(key, cjson.encode(data))
local decrypted = crypto.decrypt(key, encrypted)    -- nil if the key is wrong, or encrypted was changed
```

| | |
| --- | --- |
| `crypto.secret_key()` | a random 32 byte key |
| `crypto.encrypt(key, message)` | the message, encrypted and authenticated with XSalsa20 and Poly1305. It's 40 bytes longer, for a random nonce and the authentication tag, so each encryption of the same message is different |
| `crypto.decrypt(key, data)` | the message, or nil |

### With a public key

Anyone with the public key can seal a message, and only the owner of the secret key can unseal it, eg. so a client can send data that only one server can read.

```lua
local public_key, secret_key = crypto.key_pair()    -- share the public key, keep the secret key
local sealed = crypto.seal(public_key, 'a message')
local message = crypto.unseal(secret_key, sealed)
```

| | |
| --- | --- |
| `crypto.key_pair()` | a new public key and secret key, 32 bytes each |
| `crypto.public_key(secret_key)` | the public key of a secret key, so only the secret key needs to be stored |
| `crypto.seal(public_key, message)` | the message, sealed with X25519, XSalsa20 and Poly1305. It's 48 bytes longer |
| `crypto.unseal(secret_key, data)` | the message, or nil |

Sealing is anonymous: since anyone with the public key can seal a message, a sealed message doesn't show who sent it. To show who sent a message, send it with an HMAC of a shared key, or encrypt it with a secret key that only the two of them have.
