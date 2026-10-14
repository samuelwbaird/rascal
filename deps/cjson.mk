# Lua CJSON (OpenResty fork) — require 'cjson', require 'cjson.safe'
DEPS += cjson
cjson_VERSION := 2.1.0.19
cjson_HOME    := https://github.com/openresty/lua-cjson
cjson_URL     := https://github.com/openresty/lua-cjson/archive/refs/tags/$(cjson_VERSION).tar.gz
cjson_SHA256  := d1aded44b4cfe5ec6b395e178902aba3eed1dbe7999a753c0662222de2890ec0
cjson_LICENSE := LICENSE

cjson_SRCS := lua_cjson.c strbuf.c fpconv.c
cjson_CMODULES := cjson:luaopen_cjson cjson.safe:luaopen_cjson_safe
