# rascal — a single statically linked Lua executable with batteries included
#
#   make              build build/<platform>/bin/rascal
#   make test         build, run the test suite and check linkage
#   make fetch        download and unpack all dependency sources only
#   make dist         stripped binary + licences in dist/rascal-<version>-<platform>/
#   make info         show platform, options and pinned dependency versions
#   make clean        remove this platform's build output (keeps downloads)
#   make distclean    remove all build output, downloads and dist
#
# Dependencies are declared one per file in deps/*.mk, embedded Lua modules
# live under lua/, and rascal's own C code is in src/. See README.md.

VERSION := 0.1.0

# the default target, defined below
.PHONY: all
all:

include config.mk

# -----------------------------------------------------------------------------
# dependency declarations
#
# Each deps/<name>.mk appends <name> to DEPS and sets <name>_VERSION, _URL,
# _SHA256, _SRCS, _CMODULES, _LUA and so on. They are included first, and the
# generic rules for every dependency are generated afterwards from DEP_RULES.

# sources are fetched and extracted to $(SRC)/<dep>, marked by a stamp file
stamp = $(SRC)/$(1)/.rascal-fetched

DEPS :=
# lua first: its headers and flags are needed by everything else
include deps/lua.mk
include $(filter-out deps/lua.mk,$(sort $(wildcard deps/*.mk)))

# objects depend on every stamp, so re-fetching any dependency (eg. after a
# version change) rebuilds everything against the new headers
ALL_STAMPS := $(foreach d,$(DEPS),$(call stamp,$(d)))
DEP_INCLUDES := $(foreach d,$(DEPS),$($(d)_INCLUDES))

COMPILE_DEP    = $(CC) $(BASE_CFLAGS) $(LUA_DEFS) $(DEP_WARNINGS) $(DEP_INCLUDES)
COMPILE_RASCAL = $(CC) $(BASE_CFLAGS) $(LUA_DEFS) $(RASCAL_WARNINGS) $(DEP_INCLUDES) -Isrc

# generic rules for a dependency: fetch, compile its C sources, and list
# the C modules and Lua modules it contributes to the executable
define DEP_RULES
$(1)_DIR  := $$(SRC)/$(1)
$(1)_OBJS := $$(patsubst %.c,$$(OBJ)/$(1)/%.o,$$($(1)_SRCS))
$(1)_LUAFILES := $$(foreach m,$$($(1)_LUA),$$(word 1,$$(subst :, ,$$(m))):$$($(1)_DIR)/$$(word 2,$$(subst :, ,$$(m))))

$$(call stamp,$(1)): deps/$(1).mk scripts/fetch.sh $$(wildcard patches/$(1)/*.patch)
	@scripts/fetch.sh "$(1)" "$$($(1)_URL)" "$$($(1)_SHA256)" "$$(DOWNLOADS)" "$$($(1)_DIR)" $$($(1)_PRUNE)

# unpacked files exist once the stamp does
$$(addprefix $$($(1)_DIR)/,$$($(1)_SRCS) $$(foreach m,$$($(1)_LUA),$$(word 2,$$(subst :, ,$$(m))))): $$(call stamp,$(1)) ;

$$(OBJ)/$(1)/%.o: $$($(1)_DIR)/%.c deps/$(1).mk config.mk $$(ALL_STAMPS)
	@mkdir -p $$(@D)
	@echo "  CC    $(1)/$$*.c"
	@$$(COMPILE_DEP) $$($(1)_CFLAGS) -MMD -MP -c $$< -o $$@

-include $$($(1)_OBJS:.o=.d)
endef

$(foreach d,$(DEPS),$(eval $(call DEP_RULES,$(d))))

ALL_DEP_OBJS := $(foreach d,$(DEPS),$($(d)_OBJS))
ALL_DEP_LIBS := $(foreach d,$(DEPS),$($(d)_LIB))
ALL_CMODULES := $(foreach d,$(DEPS),$($(d)_CMODULES))

# embedded Lua: every lua/**/*.lua file plus the Lua files dependencies list
# module name from path: lua/foo/bar.lua -> foo.bar, lua/foo/init.lua -> foo
LUA_TREE_FILES := $(sort $(shell find lua -name '*.lua'))
lua_module_name = $(patsubst %.init,%,$(subst /,.,$(patsubst lua/%.lua,%,$(1))))
LUA_TREE_MODULES := $(foreach f,$(LUA_TREE_FILES),$(call lua_module_name,$(f)):$(f))
ALL_LUAMODULES := $(foreach d,$(DEPS),$($(d)_LUAFILES)) $(LUA_TREE_MODULES)
ALL_LUAFILES := $(foreach m,$(ALL_LUAMODULES),$(word 2,$(subst :, ,$(m))))

# -----------------------------------------------------------------------------
# the rascal executable

RASCAL := $(BIN)/rascal
HOST_LUA := $(BUILD)/host/lua

RASCAL_OBJS := $(OBJ)/rascal/lua.o $(OBJ)/rascal/rascal.o $(OBJ)/rascal/modules.o

all: $(RASCAL)
	@echo "built $(RASCAL)"

$(RASCAL): $(RASCAL_OBJS) $(ALL_DEP_OBJS) $(ALL_DEP_LIBS)
	@mkdir -p $(@D)
	@echo "  LINK  $@"
	@$(LINK) -o $@ $(RASCAL_OBJS) $(ALL_DEP_OBJS) $(ALL_DEP_LIBS) $(LDFLAGS) $(LIBS)

# the standard Lua interpreter, with every Lua state opened by rascal_openlibs
$(OBJ)/rascal/lua.o: $(SRC)/lua/src/lua.c config.mk $(ALL_STAMPS)
	@mkdir -p $(@D)
	@echo "  CC    rascal/lua.c"
	@$(COMPILE_DEP) -DluaL_openlibs=rascal_openlibs -DLUA_PROGNAME='"rascal"' -MMD -MP -c $< -o $@

$(OBJ)/rascal/%.o: src/%.c config.mk $(ALL_STAMPS)
	@mkdir -p $(@D)
	@echo "  CC    src/$*.c"
	@$(COMPILE_RASCAL) -MMD -MP -c $< -o $@

$(OBJ)/rascal/modules.o: $(GEN)/modules.c config.mk $(ALL_STAMPS)
	@mkdir -p $(@D)
	@echo "  CC    gen/modules.c"
	@$(COMPILE_RASCAL) -MMD -MP -c $< -o $@

-include $(RASCAL_OBJS:.o=.d)

# modules.list records everything compiled in; rewritten only when it changes
# so that adding or removing a module regenerates modules.c
.PHONY: FORCE
$(GEN)/modules.list: FORCE
	@mkdir -p $(@D)
	@{ echo "version $(VERSION)"; \
	   echo "platform $(PLATFORM)"; \
	   echo "srcroot $(SRC)"; \
	   $(foreach d,$(DEPS),echo "dep $(d) $($(d)_VERSION)";) \
	   $(foreach m,$(ALL_CMODULES),echo "cmodule $(subst :, ,$(m))";) \
	   $(foreach m,$(ALL_LUAMODULES),echo "lua $(subst :, ,$(m))";) \
	 } > $@.tmp
	@if cmp -s $@.tmp $@; then rm $@.tmp; else mv $@.tmp $@; fi

$(GEN)/modules.c: $(GEN)/modules.list tools/embed.lua $(ALL_LUAFILES) $(HOST_LUA)
	@echo "  GEN   $@"
	@$(HOST_LUA) tools/embed.lua $(GEN)/modules.list $@

# a plain Lua interpreter used to run build tools written in Lua
$(HOST_LUA): $(OBJ)/host/lua.o $(lua_OBJS)
	@mkdir -p $(@D)
	@echo "  LINK  $@"
	@$(CC) -o $@ $^ $(LDFLAGS) $(HOST_LIBS)

$(OBJ)/host/lua.o: $(SRC)/lua/src/lua.c config.mk $(ALL_STAMPS)
	@mkdir -p $(@D)
	@echo "  CC    host/lua.c"
	@$(COMPILE_DEP) -MMD -MP -c $< -o $@

-include $(OBJ)/host/lua.d

# -----------------------------------------------------------------------------
# convenience targets

.PHONY: fetch test check-linkage licenses dist info clean distclean

fetch: $(ALL_STAMPS)

test: $(RASCAL)
	@$(RASCAL) tests/run.lua $(sort $(wildcard tests/test_*.lua))
	@scripts/check-linkage.sh $(RASCAL) $(STATIC)

check-linkage: $(RASCAL)
	@scripts/check-linkage.sh $(RASCAL) $(STATIC)

licenses: $(BUILD)/LICENSES.txt

$(BUILD)/LICENSES.txt: Makefile $(wildcard deps/*.mk) $(ALL_STAMPS) $(wildcard lua/LICENSE*)
	@echo "  GEN   $@"
	@{ echo "rascal $(VERSION) includes the following software."; \
	   $(foreach d,$(DEPS),echo; echo "==============================================================================="; \
	     echo "$(d) $($(d)_VERSION)  $($(d)_HOME)"; echo "==============================================================================="; \
	     $(if $($(d)_LICENSE),$(if $($(d)_LICENSE_LINES),sed -n '$($(d)_LICENSE_LINES)p',cat) "$(SRC)/$(d)/$($(d)_LICENSE)";,echo "$($(d)_LICENSE_NOTE)";)) \
	   for f in lua/LICENSE.*; do [ -f "$$f" ] || continue; echo; \
	     echo "==============================================================================="; \
	     echo "lua/$${f#lua/LICENSE.}"; \
	     echo "==============================================================================="; cat "$$f"; done; \
	 } > $@

DIST := dist/rascal-$(VERSION)-$(PLATFORM)

dist: $(RASCAL) $(BUILD)/LICENSES.txt
	@rm -rf $(DIST)
	@mkdir -p $(DIST)
	@cp $(RASCAL) $(BUILD)/LICENSES.txt $(DIST)/
	@strip $(DIST)/rascal
	@echo "packaged $(DIST)"

info:
	@echo "rascal $(VERSION)"
	@echo "platform  $(PLATFORM)"
	@echo "static    $(STATIC)"
	@echo "build     $(BUILD)"
	@echo "cc        $(CC)"
	@echo "cxx       $(CXX)"
	@$(foreach d,$(DEPS),printf '  %-12s %s\n' "$(d)" "$($(d)_VERSION)";)

clean:
	rm -rf $(BUILD)

distclean:
	rm -rf $(BUILD_ROOT) dist
