# lsqlite3 — require 'lsqlite3', using the SQLite from deps/sqlite.mk
DEPS += lsqlite3
lsqlite3_VERSION := 0.9.6
lsqlite3_HOME    := http://lua.sqlite.org
lsqlite3_URL     := https://lua.sqlite.org/home/tarball/v$(lsqlite3_VERSION)/lsqlite3.tar.gz
lsqlite3_SHA256  := 0fda0cc37ba45e0e232e85a987f0e67ef54b4faa3fc2cc4b1e738b21ef81290b
lsqlite3_LICENSE := lsqlite3.c
lsqlite3_LICENSE_LINES := 1,27
# remove the bundled (older) copy of sqlite so the shared one is used
lsqlite3_PRUNE := sqlite3.c sqlite3.h

lsqlite3_SRCS := lsqlite3.c
lsqlite3_CFLAGS := -DLSQLITE_VERSION='"$(lsqlite3_VERSION)"'
lsqlite3_CMODULES := lsqlite3:luaopen_lsqlite3
