/*
** rascal — shared declarations between rascal.c and the generated modules.c
*/

#ifndef rascal_h
#define rascal_h

#include <stddef.h>

#include "lua.h"

/* a C module compiled into the executable, registered in package.preload */
typedef struct rascal_CModule {
  const char *name;
  lua_CFunction open;
} rascal_CModule;

/* a Lua module embedded as source, found by the embedded searcher */
typedef struct rascal_LuaModule {
  const char *name;
  const char *path;  /* source path at build time, used for the chunk name */
  const char *source;
  size_t size;
} rascal_LuaModule;

/* a dependency and its pinned version */
typedef struct rascal_Dependency {
  const char *name;
  const char *version;
} rascal_Dependency;

/* generated in modules.c, each list ends with a NULL name */
extern const char rascal_version[];
extern const char rascal_platform[];
extern const rascal_CModule rascal_cmodules[];
extern const rascal_LuaModule rascal_luamodules[];
extern const rascal_Dependency rascal_dependencies[];

/* the module run by rascal_openlibs once a state is set up */
#define RASCAL_INIT_MODULE "init"

/*
** Set from the command line by src/main.c, before any Lua state is opened,
** and applied by rascal_openlibs to every state, including each thread's.
**
**   rascal_init_enabled   cleared by --no-init
**   rascal_allow_libs     set by --allow-libs, native C modules can be loaded
**   rascal_prefer_files   set by --prefer-files, package.path is searched
**                         before the embedded modules
**   rascal_path, _cpath   package.path and package.cpath, or NULL for Lua's
**                         compiled in defaults (cpath is always empty unless
**                         native libraries are allowed)
*/
extern int rascal_init_enabled;
extern int rascal_allow_libs;
extern int rascal_prefer_files;
extern const char *rascal_path;
extern const char *rascal_cpath;

/*
** Open the standard libraries, preload the compiled in C modules, install
** the searcher for embedded Lua modules, then require the init module.
** Every Lua state rascal creates uses this in place of luaL_openlibs,
** including the interpreter's main state and each llthreads2 thread.
** Errors from the init module are raised as Lua errors.
*/
void rascal_openlibs (lua_State *L);

/* require 'rascal.build', listed in modules.c with the other C modules */
int luaopen_rascal_build (lua_State *L);

/* require 'rascal.context', the process wide ZeroMQ context as a lightuserdata */
int luaopen_rascal_context (lua_State *L);

/* pushes rascal.messaging.complete if that module is loaded, see src/main.c */
int rascal_push_complete (lua_State *L);

#endif
