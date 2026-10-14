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

/* cleared by the --no-init command line option */
extern int rascal_init_enabled;

/*
** Open the standard libraries, preload the compiled in C modules, install
** the searcher for embedded Lua modules, then require the init module.
** Every Lua state rascal creates uses this in place of luaL_openlibs,
** including the interpreter's main state and each llthreads2 thread.
** Errors from the init module are raised as Lua errors.
*/
void rascal_openlibs (lua_State *L);

int luaopen_rascal (lua_State *L);

#endif
