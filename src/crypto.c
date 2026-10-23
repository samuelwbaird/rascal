/*
** require 'rascal.crypto.core' — message digests, HMAC and base64 with
** Mbed TLS, and secure random bytes from the operating system. Used by
** lua/rascal/crypto.lua, which is the module to require.
**
**   core.digest(name, data)          the raw digest of data
**   core.hmac(name, key, data)       the raw HMAC of data
**   core.base64_encode(bytes)        base64 text
**   core.base64_decode(text)         the bytes, or nil if text isn't valid base64
**   core.random_bytes(n)             n bytes from /dev/urandom
**
** Digest names are md5, sha1, sha224, sha256, sha384 and sha512.
*/

#define MBEDTLS_CONFIG_FILE "rascal_mbedtls_config.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

#include "mbedtls/base64.h"
#include "mbedtls/md.h"


static const char *const digest_names[] = {
  "md5", "sha1", "sha224", "sha256", "sha384", "sha512", NULL
};

static const mbedtls_md_type_t digest_types[] = {
  MBEDTLS_MD_MD5, MBEDTLS_MD_SHA1, MBEDTLS_MD_SHA224,
  MBEDTLS_MD_SHA256, MBEDTLS_MD_SHA384, MBEDTLS_MD_SHA512
};

static const mbedtls_md_info_t *check_digest (lua_State *L, int arg) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(digest_types[luaL_checkoption(L, arg, NULL, digest_names)]);
  if (info == NULL)
    luaL_error(L, "crypto: digest %s is not available", lua_tostring(L, arg));
  return info;
}


static int crypto_digest (lua_State *L) {
  const mbedtls_md_info_t *info = check_digest(L, 1);
  size_t size;
  const char *data = luaL_checklstring(L, 2, &size);
  unsigned char output[MBEDTLS_MD_MAX_SIZE];
  if (mbedtls_md(info, (const unsigned char *)data, size, output) != 0)
    return luaL_error(L, "crypto: digest failed");
  lua_pushlstring(L, (const char *)output, mbedtls_md_get_size(info));
  return 1;
}


static int crypto_hmac (lua_State *L) {
  const mbedtls_md_info_t *info = check_digest(L, 1);
  size_t key_size, size;
  const char *key = luaL_checklstring(L, 2, &key_size);
  const char *data = luaL_checklstring(L, 3, &size);
  unsigned char output[MBEDTLS_MD_MAX_SIZE];
  if (mbedtls_md_hmac(info, (const unsigned char *)key, key_size, (const unsigned char *)data, size, output) != 0)
    return luaL_error(L, "crypto: hmac failed");
  lua_pushlstring(L, (const char *)output, mbedtls_md_get_size(info));
  return 1;
}


static int crypto_base64_encode (lua_State *L) {
  size_t size, length;
  const unsigned char *data = (const unsigned char *)luaL_checklstring(L, 1, &size);
  luaL_Buffer buffer;
  /* 4 characters for every 3 bytes, and the terminating zero mbedtls writes */
  size_t capacity = ((size + 2) / 3) * 4 + 1;
  unsigned char *output = (unsigned char *)luaL_buffinitsize(L, &buffer, capacity);
  if (mbedtls_base64_encode(output, capacity, &length, data, size) != 0)
    return luaL_error(L, "crypto: base64 encoding failed");
  luaL_pushresultsize(&buffer, length);
  return 1;
}


static int crypto_base64_decode (lua_State *L) {
  size_t size, length;
  const unsigned char *text = (const unsigned char *)luaL_checklstring(L, 1, &size);
  luaL_Buffer buffer;
  size_t capacity = (size / 4) * 3 + 3;
  unsigned char *output = (unsigned char *)luaL_buffinitsize(L, &buffer, capacity);
  if (mbedtls_base64_decode(output, capacity, &length, text, size) != 0) {
    lua_pushnil(L);
    return 1;
  }
  luaL_pushresultsize(&buffer, length);
  return 1;
}


static int crypto_random_bytes (lua_State *L) {
  lua_Integer count = luaL_checkinteger(L, 1);
  luaL_Buffer buffer;
  char *output;
  size_t done = 0;
  int fd;
  luaL_argcheck(L, count >= 0, 1, "count must not be negative");
  output = luaL_buffinitsize(L, &buffer, (size_t)count);
  fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0)
    return luaL_error(L, "crypto: unable to open /dev/urandom: %s", strerror(errno));
  while (done < (size_t)count) {
    ssize_t n = read(fd, output + done, (size_t)count - done);
    if (n < 0 && errno == EINTR)
      continue;
    if (n <= 0) {
      int err = errno;
      close(fd);
      return luaL_error(L, "crypto: unable to read /dev/urandom: %s", n < 0 ? strerror(err) : "end of file");
    }
    done += (size_t)n;
  }
  close(fd);
  luaL_pushresultsize(&buffer, (size_t)count);
  return 1;
}


int luaopen_rascal_crypto_core (lua_State *L) {
  static const luaL_Reg functions[] = {
    {"digest", crypto_digest},
    {"hmac", crypto_hmac},
    {"base64_encode", crypto_base64_encode},
    {"base64_decode", crypto_base64_decode},
    {"random_bytes", crypto_random_bytes},
    {NULL, NULL}
  };
  luaL_newlib(L, functions);
  return 1;
}
