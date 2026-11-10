# luautf8 — require 'lua-utf8'
DEPS += luautf8
luautf8_VERSION := 0.1.6
luautf8_HOME    := https://github.com/starwing/luautf8
luautf8_URL     := https://github.com/starwing/luautf8/archive/refs/tags/$(luautf8_VERSION).tar.gz
luautf8_SHA256  := b76873b4afb09abd00508a66887ae1658492078869f9414c334dea35b5769656
luautf8_LICENSE := LICENSE

luautf8_SRCS := lutf8lib.c
# renamed, as Lua's own utf8 library is also luaopen_utf8
luautf8_CFLAGS := -Dluaopen_utf8=luaopen_lua_utf8
luautf8_CMODULES := lua-utf8:luaopen_lua_utf8
