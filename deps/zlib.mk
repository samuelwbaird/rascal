# zlib — deflate and gzip compression, used through lua-zlib (deps/luazlib.mk)
# by rascal.http for compressed responses, request bodies and websocket messages
DEPS += zlib
zlib_VERSION := 1.3.2
zlib_HOME    := https://zlib.net
zlib_URL     := https://github.com/madler/zlib/archive/refs/tags/v$(zlib_VERSION).tar.gz
zlib_SHA256  := b99a0b86c0ba9360ec7e78c4f1e43b1cbdf1e6936c8fa0f6835c0cd694a495a1
zlib_LICENSE := LICENSE

# the in memory compression sources only, not the gz* file functions
zlib_SRCS := adler32.c compress.c crc32.c deflate.c inffast.c inflate.c inftrees.c trees.c uncompr.c zutil.c
zlib_INCLUDES := -I$(SRC)/zlib
