# build configuration — override any of these on the command line,
# eg. make DEBUG=1, make STATIC=full, make CC=gcc CXX=g++

# STATIC=deps   every third party library is statically linked, only the
#               platform's system libraries are dynamic (libc, libc++ etc.)
#               this is the default, and the only option on macOS
# STATIC=full   a completely static executable, intended for Linux with musl
#               (eg. Alpine, see scripts/docker-build.sh). Loading external C
#               modules with require is disabled as dlopen is unavailable
STATIC ?= deps

DEBUG ?= 0

UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
PLATFORM := $(shell echo $(UNAME_S) | tr A-Z a-z)-$(UNAME_M)$(if $(filter full,$(STATIC)),-static)

# each platform builds in its own directory, so one checkout can hold macOS
# and Linux (container) builds side by side, sharing the download cache
BUILD_ROOT := build
BUILD     ?= $(BUILD_ROOT)/$(PLATFORM)
DOWNLOADS := $(BUILD_ROOT)/downloads
SRC := $(BUILD)/src
OBJ := $(BUILD)/obj
GEN := $(BUILD)/gen
BIN := $(BUILD)/bin

CC  ?= cc
CXX ?= c++

ifeq ($(DEBUG),1)
  OPT := -O0 -g
else
  OPT := -O2
endif

BASE_CFLAGS := $(OPT) $(CFLAGS)
DEP_WARNINGS := -w
RASCAL_WARNINGS := -Wall -Wextra

# libzmq is C++ so the final link uses the C++ driver
LINK := $(CXX)
LDFLAGS ?=

# rascal reads RASCAL_PATH, RASCAL_CPATH and RASCAL_INIT rather than LUA_PATH,
# LUA_CPATH and LUA_INIT, so it is unaffected by any other Lua installation's
# settings, and by default only searches the current directory for modules
LUA_ENV_DEFS := \
	-DLUA_PATH_VAR='"RASCAL_PATH"' -DLUA_CPATH_VAR='"RASCAL_CPATH"' -DLUA_INIT_VAR='"RASCAL_INIT"' \
	-DLUA_PATH_DEFAULT='"./?.lua;./?/init.lua"' -DLUA_CPATH_DEFAULT='"./?.so"'

ifeq ($(UNAME_S),Darwin)
  # the oldest macOS the executable runs on, whatever it is built on
  export MACOSX_DEPLOYMENT_TARGET ?= 12.0
  # archives made here leave out macOS file attributes, which other systems warn about
  ARCHIVE_FLAGS := --no-mac-metadata --no-xattrs
  LUA_DEFS := -DLUA_COMPAT_5_3 $(LUA_ENV_DEFS) -DLUA_USE_MACOSX
  LIBS :=
  HOST_LIBS :=
  ifeq ($(STATIC),full)
    $(error STATIC=full is not supported on macOS, system libraries are always dynamic)
  endif
else
  ifeq ($(STATIC),full)
    LUA_DEFS := -DLUA_COMPAT_5_3 $(LUA_ENV_DEFS) -DLUA_USE_POSIX
    LDFLAGS += -static
  else
    LUA_DEFS := -DLUA_COMPAT_5_3 $(LUA_ENV_DEFS) -DLUA_USE_LINUX
    # export Lua API symbols so that external C modules can still be loaded
    LDFLAGS += -Wl,-E -static-libstdc++ -static-libgcc
  endif
  LIBS := -lpthread -lm -ldl
  HOST_LIBS := -lm -ldl
endif
