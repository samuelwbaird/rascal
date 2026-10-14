# SQLite — the amalgamation, compiled in directly
DEPS += sqlite
sqlite_VERSION := 3.54.0
sqlite_HOME    := https://sqlite.org
sqlite_URL     := https://sqlite.org/2026/sqlite-autoconf-3540000.tar.gz
sqlite_SHA256  := 134ec0802dda5795816e25d25872d20b312cb3973438c49b30bc40b7705ea9ed
sqlite_LICENSE_NOTE := SQLite is in the public domain.

sqlite_SRCS := sqlite3.c
sqlite_INCLUDES := -I$(SRC)/sqlite
sqlite_CFLAGS := \
	-DSQLITE_THREADSAFE=1 \
	-DSQLITE_DEFAULT_MEMSTATUS=0 \
	-DSQLITE_USE_URI=1 \
	-DSQLITE_ENABLE_FTS5 \
	-DSQLITE_ENABLE_RTREE \
	-DSQLITE_ENABLE_GEOPOLY \
	-DSQLITE_ENABLE_MATH_FUNCTIONS \
	-DSQLITE_ENABLE_COLUMN_METADATA \
	-DSQLITE_ENABLE_DBSTAT_VTAB \
	-DSQLITE_ENABLE_STAT4 \
	-DHAVE_USLEEP=1
