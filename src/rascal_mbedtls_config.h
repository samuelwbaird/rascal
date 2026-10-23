/*
** The Mbed TLS configuration for rascal (see deps/mbedtls.mk), enabling
** only what rascal.crypto uses: message digests, HMAC and base64.
**
** It is named so it can't be confused with Mbed TLS's own default
** configuration, include/mbedtls/mbedtls_config.h.
*/

#ifndef rascal_mbedtls_config_h
#define rascal_mbedtls_config_h

#define MBEDTLS_MD_C
#define MBEDTLS_MD5_C
#define MBEDTLS_SHA1_C
#define MBEDTLS_SHA224_C
#define MBEDTLS_SHA256_C
#define MBEDTLS_SHA384_C
#define MBEDTLS_SHA512_C
#define MBEDTLS_BASE64_C

#endif
