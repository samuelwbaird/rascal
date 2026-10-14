# Lua — the language itself
DEPS += lua
lua_VERSION := 5.4.9
lua_HOME    := https://www.lua.org
lua_URL     := https://www.lua.org/ftp/lua-$(lua_VERSION).tar.gz
lua_SHA256  := 2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6
lua_LICENSE := src/lua.h
lua_LICENSE_LINES := 500,519

lua_CORE_FILES := lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject \
                  lopcodes lparser lstate lstring ltable ltm lundump lvm lzio
lua_STDLIB_FILES := lauxlib lbaselib lcorolib ldblib liolib lmathlib loadlib loslib \
                    lstrlib ltablib lutf8lib linit
# lua.c (the interpreter main) is compiled separately, see the Makefile
lua_SRCS := $(foreach f,$(lua_CORE_FILES) $(lua_STDLIB_FILES),src/$(f).c)
lua_INCLUDES := -I$(SRC)/lua/src

$(SRC)/lua/src/lua.c: $(call stamp,lua) ;
