/*
** rascal.crypto.sodium — password hashing and encryption from libsodium,
** used by rascal.crypto (lua/rascal/crypto.lua), which documents them.
**
**   pwhash_str(password, strength)          an argon2id hash string
**   pwhash_str_verify(hash, password)       true if the password matches
**   pwhash_str_needs_rehash(hash, strength) true if it was hashed at another strength
**   secretbox(key, message)                 nonce .. encrypted message, for a 32 byte key
**   secretbox_open(key, data)               the message, or nil
**   box_keypair()                           public key, secret key, 32 bytes each
**   box_public_key(secret_key)              the public key of a secret key
**   box_seal(public_key, message)           the message sealed for the owner of public_key
**   box_seal_open(secret_key, data)         the message, or nil
**
** Strength is 'interactive' (the default), 'moderate' or 'sensitive'.
*/

#include <string.h>
#include <sodium.h>

#include "lua.h"
#include "lauxlib.h"

static void strength_limits (lua_State *L, int arg, unsigned long long *ops, size_t *mem) {
  static const char *const names[] = { "interactive", "moderate", "sensitive", NULL };
  switch (luaL_checkoption(L, arg, "interactive", names)) {
    case 0:
      *ops = crypto_pwhash_OPSLIMIT_INTERACTIVE; *mem = crypto_pwhash_MEMLIMIT_INTERACTIVE; break;
    case 1:
      *ops = crypto_pwhash_OPSLIMIT_MODERATE; *mem = crypto_pwhash_MEMLIMIT_MODERATE; break;
    default:
      *ops = crypto_pwhash_OPSLIMIT_SENSITIVE; *mem = crypto_pwhash_MEMLIMIT_SENSITIVE; break;
  }
}

static const unsigned char *check_key (lua_State *L, int arg, size_t size, const char *what) {
  size_t length;
  const char *key = luaL_checklstring(L, arg, &length);
  if (length != size)
    luaL_error(L, "crypto: %s must be %d bytes", what, (int)size);
  return (const unsigned char *)key;
}

/* passwords ------------------------------------------------------------------------------- */

static int sodium_pwhash_str (lua_State *L) {
  size_t length;
  const char *password = luaL_checklstring(L, 1, &length);
  unsigned long long ops;
  size_t mem;
  char hash[crypto_pwhash_STRBYTES];
  strength_limits(L, 2, &ops, &mem);
  if (crypto_pwhash_str(hash, password, length, ops, mem) != 0)
    return luaL_error(L, "crypto: not enough memory to hash a password");
  lua_pushstring(L, hash);
  return 1;
}

static int sodium_pwhash_str_verify (lua_State *L) {
  size_t hash_length, length;
  const char *hash = luaL_checklstring(L, 1, &hash_length);
  const char *password = luaL_checklstring(L, 2, &length);
  lua_pushboolean(L, hash_length < crypto_pwhash_STRBYTES
    && crypto_pwhash_str_verify(hash, password, length) == 0);
  return 1;
}

static int sodium_pwhash_str_needs_rehash (lua_State *L) {
  size_t hash_length;
  const char *hash = luaL_checklstring(L, 1, &hash_length);
  unsigned long long ops;
  size_t mem;
  strength_limits(L, 2, &ops, &mem);
  /* 0 if it matches, 1 if it doesn't, -1 if it isn't a valid hash */
  lua_pushboolean(L, hash_length >= crypto_pwhash_STRBYTES
    || crypto_pwhash_str_needs_rehash(hash, ops, mem) != 0);
  return 1;
}

/* secret key encryption ------------------------------------------------------------------- */

static int sodium_secretbox (lua_State *L) {
  const unsigned char *key = check_key(L, 1, crypto_secretbox_KEYBYTES, "a secret key");
  size_t length;
  const unsigned char *message = (const unsigned char *)luaL_checklstring(L, 2, &length);
  size_t size = crypto_secretbox_NONCEBYTES + crypto_secretbox_MACBYTES + length;
  luaL_Buffer b;
  unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, size);
  randombytes_buf(out, crypto_secretbox_NONCEBYTES);
  crypto_secretbox_easy(out + crypto_secretbox_NONCEBYTES, message, length, out, key);
  luaL_pushresultsize(&b, size);
  return 1;
}

static int sodium_secretbox_open (lua_State *L) {
  const unsigned char *key = check_key(L, 1, crypto_secretbox_KEYBYTES, "a secret key");
  size_t length;
  const unsigned char *data = (const unsigned char *)luaL_checklstring(L, 2, &length);
  if (length < crypto_secretbox_NONCEBYTES + crypto_secretbox_MACBYTES) {
    lua_pushnil(L);
    return 1;
  }
  size_t size = length - crypto_secretbox_NONCEBYTES - crypto_secretbox_MACBYTES;
  luaL_Buffer b;
  unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, size + 1);
  if (crypto_secretbox_open_easy(out, data + crypto_secretbox_NONCEBYTES,
      length - crypto_secretbox_NONCEBYTES, data, key) != 0) {
    lua_pushnil(L);
    return 1;
  }
  luaL_pushresultsize(&b, size);
  return 1;
}

/* public key encryption ------------------------------------------------------------------- */

static int sodium_box_keypair (lua_State *L) {
  unsigned char public_key[crypto_box_PUBLICKEYBYTES], secret_key[crypto_box_SECRETKEYBYTES];
  crypto_box_keypair(public_key, secret_key);
  lua_pushlstring(L, (const char *)public_key, sizeof public_key);
  lua_pushlstring(L, (const char *)secret_key, sizeof secret_key);
  sodium_memzero(secret_key, sizeof secret_key);
  return 2;
}

static int sodium_box_public_key (lua_State *L) {
  const unsigned char *secret_key = check_key(L, 1, crypto_box_SECRETKEYBYTES, "a secret key");
  unsigned char public_key[crypto_box_PUBLICKEYBYTES];
  crypto_scalarmult_base(public_key, secret_key);
  lua_pushlstring(L, (const char *)public_key, sizeof public_key);
  return 1;
}

static int sodium_box_seal (lua_State *L) {
  const unsigned char *public_key = check_key(L, 1, crypto_box_PUBLICKEYBYTES, "a public key");
  size_t length;
  const unsigned char *message = (const unsigned char *)luaL_checklstring(L, 2, &length);
  size_t size = crypto_box_SEALBYTES + length;
  luaL_Buffer b;
  unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, size);
  if (crypto_box_seal(out, message, length, public_key) != 0)
    return luaL_error(L, "crypto: could not seal the message");
  luaL_pushresultsize(&b, size);
  return 1;
}

static int sodium_box_seal_open (lua_State *L) {
  const unsigned char *secret_key = check_key(L, 1, crypto_box_SECRETKEYBYTES, "a secret key");
  size_t length;
  const unsigned char *data = (const unsigned char *)luaL_checklstring(L, 2, &length);
  if (length < crypto_box_SEALBYTES) {
    lua_pushnil(L);
    return 1;
  }
  unsigned char public_key[crypto_box_PUBLICKEYBYTES];
  crypto_scalarmult_base(public_key, secret_key);
  size_t size = length - crypto_box_SEALBYTES;
  luaL_Buffer b;
  unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, size + 1);
  if (crypto_box_seal_open(out, data, length, public_key, secret_key) != 0) {
    lua_pushnil(L);
    return 1;
  }
  luaL_pushresultsize(&b, size);
  return 1;
}

int luaopen_rascal_crypto_sodium (lua_State *L) {
  static const luaL_Reg functions[] = {
    {"pwhash_str", sodium_pwhash_str},
    {"pwhash_str_verify", sodium_pwhash_str_verify},
    {"pwhash_str_needs_rehash", sodium_pwhash_str_needs_rehash},
    {"secretbox", sodium_secretbox},
    {"secretbox_open", sodium_secretbox_open},
    {"box_keypair", sodium_box_keypair},
    {"box_public_key", sodium_box_public_key},
    {"box_seal", sodium_box_seal},
    {"box_seal_open", sodium_box_seal_open},
    {NULL, NULL}
  };
  /* safe to call from every thread, it initialises once */
  if (sodium_init() < 0)
    return luaL_error(L, "crypto: libsodium could not be initialised");
  luaL_newlib(L, functions);
  lua_pushinteger(L, crypto_secretbox_KEYBYTES);
  lua_setfield(L, -2, "secret_key_size");
  return 1;
}
