/*
** the host lua used to run build tools is built from the same patched lua.c
** as rascal, without the rest of rascal, so it never has anything to complete
*/

#include "lua.h"

int rascal_push_complete (lua_State *L) {
  (void)L;
  return 0;
}
