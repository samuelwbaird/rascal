# Mbed TLS — only its hashing, HMAC and base64 sources, used by rascal.crypto
# through its own binding in src/crypto.c (require 'rascal.crypto.core').
# Configured by src/rascal_mbedtls_config.h, which enables only those parts.
DEPS += mbedtls
mbedtls_VERSION := 3.6.7
mbedtls_HOME    := https://www.trustedfirmware.org/projects/mbed-tls/
mbedtls_URL     := https://github.com/Mbed-TLS/mbedtls/archive/refs/tags/mbedtls-$(mbedtls_VERSION).tar.gz
mbedtls_SHA256  := 807f0a1cc7c63b571180e9efeb6236b677e550869eb0442ace33aa9c69055fcc
mbedtls_LICENSE := LICENSE

mbedtls_SRCS := $(addprefix library/,md.c md5.c sha1.c sha256.c sha512.c base64.c platform_util.c constant_time.c)
mbedtls_CFLAGS := -Isrc -DMBEDTLS_CONFIG_FILE='"rascal_mbedtls_config.h"'
mbedtls_INCLUDES := -I$(SRC)/mbedtls/include
mbedtls_CMODULES := rascal.crypto.core:luaopen_rascal_crypto_core
