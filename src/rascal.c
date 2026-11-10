/*
** rascal — opening Lua states with the compiled in and embedded modules
*/

#include <pthread.h>
#include <string.h>

#include "zmq.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "rascal.h"


int rascal_init_enabled = 1;
int rascal_allow_libs = 0;
int rascal_prefer_files = 0;
const char *rascal_path = NULL;
const char *rascal_cpath = NULL;


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


/* package.loadlib, when native libraries are not allowed */
static int no_loadlib (lua_State *L) {
  luaL_pushfail(L);
  lua_pushliteral(L, "native libraries are not allowed, start rascal with --allow-libs");
  lua_pushliteral(L, "absent");
  return 3;
}


/*
** Set the module search paths, and unless native libraries are allowed,
** remove the searchers for C modules (the 3rd and 4th, after preload and
** Lua files) and package.loadlib. Then insert the embedded searcher
** straight after package.preload, so the executable behaves the same
** wherever it runs, or after package.path with --prefer-files, eg. while
** working on an embedded module.
*/
static void setup_package (lua_State *L) {
  lua_Integer position = rascal_prefer_files ? 3 : 2;
  lua_Integer i;

  lua_getglobal(L, LUA_LOADLIBNAME);
  if (rascal_path != NULL) {
    lua_pushstring(L, rascal_path);
    lua_setfield(L, -2, "path");
  }
  if (rascal_cpath != NULL) {
    lua_pushstring(L, rascal_cpath);
    lua_setfield(L, -2, "cpath");
  }
  if (!rascal_allow_libs) {
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "cpath");
    lua_pushcfunction(L, no_loadlib);
    lua_setfield(L, -2, "loadlib");
  }

  lua_getfield(L, -1, "searchers");
  if (!rascal_allow_libs) {
    lua_pushnil(L);
    lua_rawseti(L, -2, 4);
    lua_pushnil(L);
    lua_rawseti(L, -2, 3);
  }
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

  /* package.path and cpath never come from LUA_PATH or LUA_CPATH */
  lua_pushboolean(L, 1);
  lua_setfield(L, LUA_REGISTRYINDEX, "LUA_NOENV");
  luaL_openlibs(L);

  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  for (m = rascal_cmodules; m->name != NULL; m++) {
    lua_pushcfunction(L, m->open);
    lua_setfield(L, -2, m->name);
  }
  lua_pop(L, 1);

  setup_package(L);

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
** Called by the interpreter once the script and any interactive prompt are
** complete. If rascal.messaging has been loaded, push its complete function
** to run this thread's loop until all of its work is done.
*/
int rascal_push_complete (lua_State *L) {
  lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
  lua_getfield(L, -1, "rascal.messaging");
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "complete");
    if (lua_isfunction(L, -1)) {
      lua_replace(L, -3);
      lua_pop(L, 1);
      return 1;
    }
    lua_pop(L, 1);
  }
  lua_pop(L, 2);
  return 0;
}


/*
** require 'rascal.context' — the process wide ZeroMQ context, as a
** lightuserdata for lzmq's zmq.init_ctx. It is created once and never
** terminated, so ending any Lua state (or the process) never blocks on, or
** interrupts, sockets in other threads.
*/

static void *zmq_context = NULL;
static pthread_once_t zmq_context_once = PTHREAD_ONCE_INIT;

static void create_zmq_context (void) {
  zmq_context = zmq_ctx_new();
}

int luaopen_rascal_context (lua_State *L) {
  pthread_once(&zmq_context_once, create_zmq_context);
  if (zmq_context == NULL)
    return luaL_error(L, "unable to create the ZeroMQ context: %s", zmq_strerror(zmq_errno()));
  lua_pushlightuserdata(L, zmq_context);
  return 1;
}


/*
** require 'rascal.build' — what this executable was built with
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


int luaopen_rascal_build (lua_State *L) {
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
