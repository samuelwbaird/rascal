# lua-cmsgpack — require 'cmsgpack', require 'cmsgpack.safe'
DEPS += cmsgpack
cmsgpack_VERSION := 0.4.0
cmsgpack_HOME    := https://github.com/antirez/lua-cmsgpack
cmsgpack_URL     := https://github.com/antirez/lua-cmsgpack/archive/refs/tags/$(cmsgpack_VERSION).tar.gz
cmsgpack_SHA256  := ed00bbcce9c6589aad71b96d5bc88b7581186b3abd38ae887cb1f265a19fa3e5
cmsgpack_LICENSE := lua_cmsgpack.c
cmsgpack_LICENSE_LINES := 950,969

cmsgpack_SRCS := lua_cmsgpack.c
cmsgpack_CMODULES := cmsgpack:luaopen_cmsgpack cmsgpack.safe:luaopen_cmsgpack_safe
