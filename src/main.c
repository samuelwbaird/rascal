/*
** rascal — command line entry point
**
** Options specific to rascal are removed from the command line here, and the
** rest is handed to the standard Lua interpreter (lua.c, compiled with its
** main renamed to lua_main), so all of its usual options work unchanged.
**
**   --no-init   do not run the init module in each new Lua state
*/

#include <string.h>

#include "rascal.h"

int lua_main (int argc, char **argv);


int main (int argc, char **argv) {
  int i, n = 1;
  int in_options = 1;

  for (i = 1; i < argc; i++) {
    const char *a = argv[i];
    if (in_options) {
      if (strcmp(a, "--no-init") == 0) {
        rascal_init_enabled = 0;
        continue;
      }
      if (a[0] != '-' || strcmp(a, "-") == 0 || strcmp(a, "--") == 0) {
        /* the script name, stdin or end of options: the rest is untouched */
        in_options = 0;
      }
      else if ((a[1] == 'e' || a[1] == 'l') && a[2] == '\0' && i + 1 < argc) {
        /* -e and -l take the next argument, keep the pair together */
        argv[n++] = argv[i++];
      }
    }
    argv[n++] = argv[i];
  }
  argv[n] = NULL;

  return lua_main(n, argv);
}
