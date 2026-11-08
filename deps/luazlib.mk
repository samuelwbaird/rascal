# lua-zlib — require 'zlib', streaming deflate and inflate with the zlib above
DEPS += luazlib
luazlib_VERSION := 1.4
luazlib_HOME    := https://github.com/brimworks/lua-zlib
luazlib_URL     := https://github.com/brimworks/lua-zlib/archive/refs/tags/v$(luazlib_VERSION).tar.gz
luazlib_SHA256  := c2a59e96d2df6e192cf0bf6f19b312977ce24020c4072426c0cf8b6594767308
luazlib_LICENSE := LICENCE

luazlib_SRCS := lua_zlib.c
luazlib_CMODULES := zlib:luaopen_zlib
