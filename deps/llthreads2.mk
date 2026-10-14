# lua-llthreads2 — require 'llthreads2', native threads each with a Lua state
DEPS += llthreads2
llthreads2_VERSION := 0.1.6
llthreads2_HOME    := https://github.com/moteus/lua-llthreads2
llthreads2_URL     := https://github.com/moteus/lua-llthreads2/archive/refs/tags/v$(llthreads2_VERSION).tar.gz
llthreads2_SHA256  := 6c39b6e86b0d3f865b0fc1bfe3d1794785fcebe199f7f0fdc1e777982f80916d
llthreads2_LICENSE := LICENSE

llthreads2_SRCS := src/llthread.c src/l52util.c
# new thread states are opened with rascal_openlibs, so they have the same
# compiled in C modules and embedded Lua modules as the main state
llthreads2_CFLAGS := -DLLTHREAD_MODULE_NAME=llthreads2 -DluaL_openlibs=rascal_openlibs
llthreads2_CMODULES := llthreads2:luaopen_llthreads2
llthreads2_LUA := llthreads2.ex:src/lua/llthreads2/ex.lua
