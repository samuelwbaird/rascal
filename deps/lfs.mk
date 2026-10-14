# LuaFileSystem — require 'lfs'
DEPS += lfs
lfs_VERSION := 1.9.0
lfs_HOME    := https://github.com/lunarmodules/luafilesystem
lfs_URL     := https://github.com/lunarmodules/luafilesystem/archive/refs/tags/v1_9_0.tar.gz
lfs_SHA256  := 1142c1876e999b3e28d1c236bf21ffd9b023018e336ac25120fb5373aade1450
lfs_LICENSE := LICENSE

lfs_SRCS := src/lfs.c
lfs_CMODULES := lfs:luaopen_lfs
