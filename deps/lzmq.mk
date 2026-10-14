# lzmq — require 'lzmq', ZeroMQ bindings using the libzmq from deps/zeromq.mk
DEPS += lzmq
lzmq_VERSION := 0.4.4-210609b
lzmq_HOME    := https://github.com/zeromq/lzmq
lzmq_URL     := https://github.com/zeromq/lzmq/archive/210609b27c6955854a9f44e5b6df1ac8b06cc8f8.tar.gz
lzmq_SHA256  := d756758b000dadc3af80cebc518fd89786912cf343cf0880eb893cba6424b9c7
lzmq_LICENSE := LICENCE.txt

lzmq_SRCS := src/lzmq.c src/lzutils.c src/poller.c src/zcontext.c src/zerror.c \
             src/zmsg.c src/zpoller.c src/zsocket.c src/ztimer.c
lzmq_CFLAGS := -DLUAZMQ_USE_SEND_AS_BUF -DLUAZMQ_USE_TEMP_BUFFERS -DLUAZMQ_USE_ERR_TYPE_OBJECT
lzmq_CMODULES := lzmq:luaopen_lzmq lzmq.timer:luaopen_lzmq_timer
# the ffi variants are for LuaJIT only and are left out
lzmq_LUA := \
	lzmq.loop:src/lua/lzmq/loop.lua \
	lzmq.poller:src/lua/lzmq/poller.lua \
	lzmq.threads:src/lua/lzmq/threads.lua \
	lzmq.llthreads.ex:src/lua/lzmq/llthreads/ex.lua \
	lzmq.impl.threads:src/lua/lzmq/impl/threads.lua \
	lzmq.impl.loop:src/lua/lzmq/impl/loop.lua
