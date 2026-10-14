/*
** rascal — opening Lua states with the compiled in and embedded modules
*/

#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "rascal.h"


int rascal_init_enabled = 1;


static const rascal_LuaModule *find_luamodule (const char *name) {
  const rascal_LuaModule *m;
  for (m = rascal_luamodules; m->name != NULL; m++) {
    if (strcmp(m->name, name) == 0)
      return m;
  }
  return NULL;
}


static int load_luamodule (lua_State *L, const rascal_LuaModule *m) {
  lua_pushfstring(L, "@%s", m->path);
  int status = luaL_loadbufferx(L, m->source, m->size, lua_tostring(L, -1), "t");
  lua_remove(L, -2);
  return status;
}


/* package.searchers entry for modules embedded in the executable */
static int searcher_embedded (lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  const rascal_LuaModule *m = find_luamodule(name);
  if (m == NULL) {
    lua_pushfstring(L, "no embedded module '%s'", name);
    return 1;
  }
  if (load_luamodule(L, m) != LUA_OK) {
    return luaL_error(L, "error loading embedded module '%s':\n\t%s",
                      name, lua_tostring(L, -1));
  }
  lua_pushfstring(L, "embedded:%s", m->path);
  return 2;
}


/*
** Embedded modules are searched straight after package.preload, so the
** executable behaves the same wherever it runs. Set RASCAL_PREFER_FILES=1
** to search package.path first, eg. while working on an embedded module.
*/
static void install_searcher (lua_State *L) {
  const char *prefer_files = getenv("RASCAL_PREFER_FILES");
  lua_Integer position = (prefer_files && *prefer_files && strcmp(prefer_files, "0") != 0) ? 3 : 2;
  lua_Integer i;

  lua_getglobal(L, LUA_LOADLIBNAME);
  lua_getfield(L, -1, "searchers");
  for (i = (lua_Integer)lua_rawlen(L, -1); i >= position; i--) {
    lua_rawgeti(L, -1, i);
    lua_rawseti(L, -2, i + 1);
  }
  lua_pushcfunction(L, searcher_embedded);
  lua_rawseti(L, -2, position);
  lua_pop(L, 2);
}


void rascal_openlibs (lua_State *L) {
  const rascal_CModule *m;

  luaL_openlibs(L);

  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_rascal);
  lua_setfield(L, -2, "rascal");
  for (m = rascal_cmodules; m->name != NULL; m++) {
    lua_pushcfunction(L, m->open);
    lua_setfield(L, -2, m->name);
  }
  lua_pop(L, 1);

  install_searcher(L);

  if (rascal_init_enabled) {
    lua_getglobal(L, "require");
    lua_pushliteral(L, RASCAL_INIT_MODULE);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
      lua_pushfstring(L, "rascal init failed: %s", lua_tostring(L, -1));
      lua_error(L);
    }
  }
}


/*
** require 'rascal' — what this executable was built with
*/

/* rascal.source(name) returns the source of an embedded Lua module */
static int rascal_source (lua_State *L) {
  const rascal_LuaModule *m = find_luamodule(luaL_checkstring(L, 1));
  if (m == NULL)
    return 0;
  lua_pushlstring(L, m->source, m->size);
  lua_pushstring(L, m->path);
  return 2;
}


int luaopen_rascal (lua_State *L) {
  const rascal_CModule *c;
  const rascal_LuaModule *l;
  const rascal_Dependency *d;
  int i;

  lua_newtable(L);

  lua_pushstring(L, rascal_version);
  lua_setfield(L, -2, "version");
  lua_pushstring(L, rascal_platform);
  lua_setfield(L, -2, "platform");
  lua_pushliteral(L, LUA_RELEASE);
  lua_setfield(L, -2, "lua_version");
  lua_pushboolean(L, rascal_init_enabled);
  lua_setfield(L, -2, "initialised");

  lua_newtable(L);
  for (d = rascal_dependencies; d->name != NULL; d++) {
    lua_pushstring(L, d->version);
    lua_setfield(L, -2, d->name);
  }
  lua_setfield(L, -2, "dependencies");

  lua_newtable(L);
  for (c = rascal_cmodules, i = 1; c->name != NULL; c++, i++) {
    lua_pushstring(L, c->name);
    lua_rawseti(L, -2, i);
  }
  lua_setfield(L, -2, "c_modules");

  lua_newtable(L);
  for (l = rascal_luamodules, i = 1; l->name != NULL; l++, i++) {
    lua_pushstring(L, l->name);
    lua_rawseti(L, -2, i);
  }
  lua_setfield(L, -2, "lua_modules");

  lua_pushcfunction(L, rascal_source);
  lua_setfield(L, -2, "source");

  return 1;
}
