/*
** rascal — command line entry point, and the interactive prompt
**
** rascal has its own options rather than those of the standard Lua
** interpreter (lua.c), and its prompt uses linenoise for line editing, Tab
** completion, and history kept in ~/.rascal_history.
**
**   rascal [options] [script [args]]
**
** Options are read first, then every Lua state is set up the same way (see
** rascal_openlibs), then --exec and --load run in the order given, then the
** script. Anything after the script name is an argument to the script.
*/

#include <ctype.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "linenoise.h"

#include "rascal.h"

#define PROGNAME "rascal"
#define PROMPT   "> "
#define PROMPT2  ">> "
#define HISTORY_LENGTH 1000
#define HISTORY_FILE ".rascal_history"  /* in $HOME */

static const char usage_text[] =
  "usage: " PROGNAME " [options] [script [args]]\n"
  "\n"
  "  --exec code     run Lua code\n"
  "  --load file     run a Lua file, then continue to the prompt\n"
  "  --multiline     wrap long lines at the prompt, rather than scrolling them\n"
  "  --path dir      find Lua modules in dir, rather than the current directory\n"
  "                  (repeat it to search more than one directory)\n"
  "  --allow-libs    allow native C modules, and use Lua's default search paths\n"
  "                  unless --path is given\n"
  "  --prefer-files  search for modules on the path before the embedded modules\n"
  "  --no-init       do not run the init module in each Lua state\n"
  "  -v, --version   show the rascal and Lua versions\n"
  "  -h, --help      show this help\n"
  "  -               run stdin as the script\n"
  "  --              stop handling options\n"
  "\n"
  "With no script, --exec or --load, rascal runs the prompt, or runs stdin as\n"
  "the script if it is not a terminal.\n";


/* the command line, once its options are read */
typedef struct Options {
  int argc;
  char **argv;
  int script;       /* argv index of the script, or 0 for none */
  int has_exec;     /* --exec was given */
  int has_load;     /* --load was given */
  int version;      /* -v */
  int multiline;    /* --multiline */
  int path_count;   /* how many --path options */
} Options;


static void message (const char *msg) {
  fprintf(stderr, "%s: %s\n", PROGNAME, msg);
  fflush(stderr);
}


/* --------------------------------------------------------------------------
** running Lua code, with a traceback on error and Ctrl-C handling, as lua.c
*/

static lua_State *globalL = NULL;

static void lstop (lua_State *L, lua_Debug *ar) {
  (void)ar;
  lua_sethook(L, NULL, 0, 0);
  luaL_error(L, "interrupted!");
}

/* on Ctrl-C, stop the running Lua code at its next step */
static void laction (int i) {
  signal(i, SIG_DFL);  /* a second Ctrl-C ends the process */
  lua_sethook(globalL, lstop, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
}

static int msghandler (lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  if (msg == NULL) {
    if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING)
      return 1;
    msg = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
  }
  luaL_traceback(L, L, msg, 1);
  return 1;
}

static int docall (lua_State *L, int narg, int nres) {
  int status;
  int base = lua_gettop(L) - narg;
  lua_pushcfunction(L, msghandler);
  lua_insert(L, base);
  globalL = L;
  signal(SIGINT, laction);
  status = lua_pcall(L, narg, nres, base);
  signal(SIGINT, SIG_DFL);
  lua_remove(L, base);
  return status;
}

static int report (lua_State *L, int status) {
  if (status != LUA_OK) {
    const char *msg = lua_tostring(L, -1);
    message(msg != NULL ? msg : "(error object is not a string)");
    lua_pop(L, 1);
  }
  return status;
}

static int dochunk (lua_State *L, int status) {
  if (status == LUA_OK)
    status = docall(L, 0, 0);
  return report(L, status);
}


/* arg holds the script at 0, its arguments from 1, and rascal and its
** options at negative indices, as in lua.c */
static void create_arg_table (lua_State *L, const Options *o) {
  int base = o->script ? o->script : o->argc;
  int i;
  lua_createtable(L, o->argc - base, base + 1);
  for (i = 0; i < o->argc; i++) {
    lua_pushstring(L, o->argv[i]);
    lua_rawseti(L, -2, i - base);
  }
  lua_setglobal(L, "arg");
}

static int run_script (lua_State *L, const Options *o) {
  const char *name = o->argv[o->script];
  int status = luaL_loadfile(L, strcmp(name, "-") == 0 ? NULL : name);
  if (status == LUA_OK) {
    int i, n = o->argc - o->script - 1;
    luaL_checkstack(L, n + 3, "too many arguments to script");
    for (i = 1; i <= n; i++)
      lua_pushstring(L, o->argv[o->script + i]);
    status = docall(L, n, 0);
  }
  return report(L, status);
}


/* --------------------------------------------------------------------------
** the interactive prompt
*/

#define CANCELLED (-2)
#define END_OF_INPUT (-1)

/* where history is kept, only for a prompt at a terminal, or NULL */
static char *history_file = NULL;

/* read a line, returning NULL at the end of input or when Ctrl-C clears it */
static char *read_line (const char *prompt, int *cancelled) {
  char *line;
  errno = 0;
  line = linenoise(prompt);
  *cancelled = (line == NULL && errno == EAGAIN);
  if (line != NULL && line[0] != '\0') {
    linenoiseHistoryAdd(line);
    if (history_file != NULL)
      linenoiseHistorySave(history_file);  /* each line, so none are lost on os.exit */
  }
  return line;
}


/* tab completion of keywords, globals and fields, eg. "string.fo" or "s:up" */

static lua_State *completion_state = NULL;

static const char *const keywords[] = {
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
  "true", "until", "while", NULL
};

static int is_name_char (char c) {
  return isalnum((unsigned char)c) || c == '_';
}

static int is_identifier (const char *s) {
  if (!isalpha((unsigned char)*s) && *s != '_')
    return 0;
  while (*s && is_name_char(*s))
    s++;
  return *s == '\0';
}

static int compare_strings (const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* add the matching names of the table at the top of the stack, and of any
** __index tables in its metatables, to the set of matches at matches */
static void collect_matches (lua_State *L, int matches, const char *prefix, int methods) {
  size_t len = strlen(prefix);
  int depth;
  for (depth = 0; depth < 8; depth++) {
    if (lua_istable(L, -1)) {
      lua_pushnil(L);
      while (lua_next(L, -2)) {
        if (lua_type(L, -2) == LUA_TSTRING && (!methods || lua_isfunction(L, -1))) {
          const char *key = lua_tostring(L, -2);
          if (strncmp(key, prefix, len) == 0 && is_identifier(key)) {
            lua_pushvalue(L, -2);
            lua_pushboolean(L, 1);
            lua_rawset(L, matches);
          }
        }
        lua_pop(L, 1);
      }
    }
    /* methods and inherited fields, eg. string methods or prelude classes */
    if (!lua_getmetatable(L, -1))
      return;
    lua_pushliteral(L, "__index");
    lua_rawget(L, -2);
    lua_remove(L, -2);
    lua_remove(L, -2);
    if (!lua_istable(L, -1))
      return;
  }
}

/* in protected mode, with the line and the linenoise completions */
static int pcomplete (lua_State *L) {
  const char *line = (const char *)lua_touserdata(L, 1);
  linenoiseCompletions *lc = (linenoiseCompletions *)lua_touserdata(L, 2);
  size_t len = strlen(line), start = len, count = 0, i;
  const char *word, *separator = NULL, *p, *prefix;
  const char **names;
  int matches;

  /* the name being typed, with any table and field names before it */
  while (start > 0 && (is_name_char(line[start - 1]) || line[start - 1] == '.' || line[start - 1] == ':'))
    start--;
  word = line + start;
  if (*word == '\0')
    return 0;  /* nothing typed, so Tab inserts a tab */
  for (p = word; *p; p++) {
    if (*p == '.' || *p == ':')
      separator = p;
  }
  if (separator != NULL && (word[0] == '.' || word[0] == ':' || (strchr(word, ':') != NULL && *separator != ':')))
    return 0;  /* after an expression, or a field after a method, is not a name */
  prefix = separator ? separator + 1 : word;

  lua_newtable(L);
  matches = lua_gettop(L);
  lua_pushglobaltable(L);
  for (p = word; separator != NULL && p < separator; ) {
    const char *end = p;
    while (end < separator && *end != '.' && *end != ':')
      end++;
    if (!lua_istable(L, -1))
      return 0;
    lua_pushlstring(L, p, (size_t)(end - p));
    lua_rawget(L, -2);
    lua_remove(L, -2);
    p = end + 1;
  }
  collect_matches(L, matches, prefix, separator != NULL && *separator == ':');
  if (separator == NULL) {
    for (i = 0; keywords[i] != NULL; i++) {
      if (strncmp(keywords[i], prefix, strlen(prefix)) == 0) {
        lua_pushstring(L, keywords[i]);
        lua_pushboolean(L, 1);
        lua_rawset(L, matches);
      }
    }
  }

  /* each match completes the whole line, in order */
  lua_pushnil(L);
  while (lua_next(L, matches)) {
    count++;
    lua_pop(L, 1);
  }
  names = (const char **)lua_newuserdatauv(L, (count + 1) * sizeof(const char *), 0);
  count = 0;
  lua_pushnil(L);
  while (lua_next(L, matches)) {
    names[count++] = lua_tostring(L, -2);  /* kept alive by the matches table */
    lua_pop(L, 1);
  }
  qsort(names, count, sizeof(const char *), compare_strings);
  for (i = 0; i < count; i++) {
    lua_pushlstring(L, line, (size_t)(prefix - line));
    lua_pushstring(L, names[i]);
    lua_concat(L, 2);
    linenoiseAddCompletion(lc, lua_tostring(L, -1));
    lua_pop(L, 1);
  }
  return 0;
}

static void complete (const char *line, linenoiseCompletions *lc) {
  lua_State *L = completion_state;
  int top = lua_gettop(L);
  lua_pushcfunction(L, pcomplete);
  lua_pushlightuserdata(L, (void *)line);
  lua_pushlightuserdata(L, lc);
  lua_pcall(L, 2, 0, 0);  /* an error only means no completions */
  lua_settop(L, top);
}

/* whether a syntax error is only that the statement is not finished */
static int incomplete (lua_State *L, int status) {
  if (status == LUA_ERRSYNTAX) {
    size_t len;
    const char *msg = lua_tolstring(L, -1, &len);
    const size_t mark = sizeof("<eof>") - 1;
    if (len >= mark && strcmp(msg + len - mark, "<eof>") == 0) {
      lua_pop(L, 1);
      return 1;
    }
  }
  return 0;
}

/* try the line as an expression, so its value is shown */
static int load_expression (lua_State *L) {
  const char *line = lua_tostring(L, 1);
  const char *code = lua_pushfstring(L, "return %s;", line);
  int status = luaL_loadbuffer(L, code, strlen(code), "=stdin");
  if (status == LUA_OK)
    lua_remove(L, -2);
  else
    lua_pop(L, 2);
  return status;
}

/* load the line as a statement, reading more lines while it is unfinished */
static int load_statement (lua_State *L) {
  for (;;) {
    size_t len;
    int cancelled;
    char *more;
    const char *code = lua_tolstring(L, 1, &len);
    int status = luaL_loadbuffer(L, code, len, "=stdin");
    if (!incomplete(L, status))
      return status;
    more = read_line(PROMPT2, &cancelled);
    if (more == NULL)
      return CANCELLED;  /* Ctrl-C or Ctrl-D abandons the statement */
    lua_pushliteral(L, "\n");
    lua_pushstring(L, more);
    linenoiseFree(more);
    lua_concat(L, 3);
  }
}

/* read and load the next statement, leaving its function on the stack */
static int load_line (lua_State *L) {
  int status, cancelled;
  char *line;
  lua_settop(L, 0);
  line = read_line(PROMPT, &cancelled);
  if (line == NULL)
    return cancelled ? CANCELLED : END_OF_INPUT;
  lua_pushstring(L, line);
  linenoiseFree(line);
  if ((status = load_expression(L)) != LUA_OK)
    status = load_statement(L);
  if (status != CANCELLED)
    lua_remove(L, 1);
  return status;
}

static void print_results (lua_State *L) {
  int n = lua_gettop(L);
  if (n > 0) {
    luaL_checkstack(L, LUA_MINSTACK, "too many results to print");
    lua_getglobal(L, "print");
    lua_insert(L, 1);
    if (lua_pcall(L, n, 0, 0) != LUA_OK)
      message(lua_pushfstring(L, "error calling 'print' (%s)", lua_tostring(L, -1)));
  }
}

static void prompt (lua_State *L, const Options *o) {
  int status;
  linenoiseSetMultiLine(o->multiline);
  linenoiseHistorySetMaxLen(HISTORY_LENGTH);
  completion_state = L;
  linenoiseSetCompletionCallback(complete);
  if (isatty(STDIN_FILENO)) {
    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
      history_file = malloc(strlen(home) + sizeof("/" HISTORY_FILE));
      if (history_file != NULL) {
        sprintf(history_file, "%s/%s", home, HISTORY_FILE);
        linenoiseHistoryLoad(history_file);
      }
    }
    printf("%s %s (%s), Ctrl-D to exit\n", PROGNAME, rascal_version, LUA_RELEASE);
    fflush(stdout);
  }
  while ((status = load_line(L)) != END_OF_INPUT) {
    if (status == CANCELLED)
      continue;
    if (status == LUA_OK)
      status = docall(L, 0, LUA_MULTRET);
    if (status == LUA_OK)
      print_results(L);
    else
      report(L, status);
  }
  lua_settop(L, 0);
}


/* --------------------------------------------------------------------------
** the command line
*/

static int usage_error (const char *msg, const char *option) {
  fprintf(stderr, "%s: %s '%s', see %s --help\n", PROGNAME, msg, option, PROGNAME);
  return 0;
}

/* whether an option takes the next argument as its value */
static int takes_value (const char *a) {
  return strcmp(a, "--exec") == 0 || strcmp(a, "--load") == 0 || strcmp(a, "--path") == 0;
}

/* read the options, and those that set up Lua states, returning 0 on error */
static int read_options (Options *o) {
  int i;
  for (i = 1; i < o->argc; i++) {
    const char *a = o->argv[i];
    if (strcmp(a, "--") == 0) {
      if (i + 1 < o->argc)
        o->script = i + 1;
      return 1;
    }
    if (a[0] != '-' || strcmp(a, "-") == 0) {
      o->script = i;
      return 1;
    }
    if (takes_value(a)) {
      if (i + 1 >= o->argc)
        return usage_error("missing a value after", a);
      if (strcmp(a, "--exec") == 0) o->has_exec = 1;
      else if (strcmp(a, "--load") == 0) o->has_load = 1;
      else o->path_count++;
      i++;
    }
    else if (strcmp(a, "--multiline") == 0) o->multiline = 1;
    else if (strcmp(a, "--allow-libs") == 0) rascal_allow_libs = 1;
    else if (strcmp(a, "--prefer-files") == 0) rascal_prefer_files = 1;
    else if (strcmp(a, "--no-init") == 0) rascal_init_enabled = 0;
    else if (strcmp(a, "-v") == 0 || strcmp(a, "--version") == 0) o->version = 1;
    else if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
      fputs(usage_text, stdout);
      exit(EXIT_SUCCESS);
    }
    else
      return usage_error("unknown option", a);
  }
  return 1;
}

/* the end of the options, the script or argc */
static int options_end (const Options *o) {
  return o->script ? o->script : o->argc;
}

/* package.path, and package.cpath if native libraries are allowed, from the
** --path directories, or the current directory by default */
static int build_paths (const Options *o) {
  size_t size = 1;
  char *path, *cpath;
  int i, end = options_end(o);

  if (o->path_count == 0) {
    /* with native libraries allowed, Lua's own defaults (NULL) are used */
    if (!rascal_allow_libs)
      rascal_path = "./?.lua;./?/init.lua";
    return 1;
  }
  for (i = 1; i < end; i++) {
    if (takes_value(o->argv[i]))
      size += 2 * strlen(o->argv[++i]) + sizeof("/?.lua;/?/init.lua;");
  }
  path = malloc(size);
  cpath = malloc(size);
  if (path == NULL || cpath == NULL) {
    message("not enough memory");
    return 0;
  }
  path[0] = cpath[0] = '\0';

  for (i = 1; i < end; i++) {
    const char *a = o->argv[i], *dir;
    int len;
    if (!takes_value(a))
      continue;
    dir = o->argv[++i];
    if (strcmp(a, "--path") != 0)
      continue;
    if (dir[0] == '\0' || strpbrk(dir, ";?") != NULL)
      return usage_error("--path needs a directory name without ; or ?, not", dir);
    len = (int)strlen(dir);
    while (len > 1 && dir[len - 1] == '/')
      len--;
    sprintf(path + strlen(path), "%.*s/?.lua;%.*s/?/init.lua;", len, dir, len, dir);
    sprintf(cpath + strlen(cpath), "%.*s/?.so;", len, dir);
  }
  path[strlen(path) - 1] = '\0';  /* the last ; */
  cpath[strlen(cpath) - 1] = '\0';
  rascal_path = path;
  rascal_cpath = cpath;
  return 1;
}

/* run --exec and --load in the order given, stopping at the first error */
static int run_options (lua_State *L, const Options *o) {
  int i, end = options_end(o);
  for (i = 1; i < end; i++) {
    const char *a = o->argv[i];
    if (!takes_value(a))
      continue;
    i++;
    if (strcmp(a, "--exec") == 0) {
      const char *code = o->argv[i];
      if (dochunk(L, luaL_loadbuffer(L, code, strlen(code), "=(command line)")) != LUA_OK)
        return 0;
    }
    else if (strcmp(a, "--load") == 0) {
      if (dochunk(L, luaL_loadfile(L, o->argv[i])) != LUA_OK)
        return 0;
    }
  }
  return 1;
}


/* everything, in protected mode, returning whether it all succeeded */
static int pmain (lua_State *L) {
  const Options *o = (const Options *)lua_touserdata(L, 1);
  int run_prompt = o->has_load;
  int nothing_else = !o->script && !o->has_exec && !o->has_load;

  luaL_checkversion(L);
  rascal_openlibs(L);
  create_arg_table(L, o);
  lua_gc(L, LUA_GCRESTART);
  lua_gc(L, LUA_GCGEN, 0, 0);

  if (o->version) {
    printf("%s %s (%s)\n", PROGNAME, rascal_version, LUA_RELEASE);
    fflush(stdout);
    if (nothing_else)
      goto done;
  }
  if (!run_options(L, o))
    return 0;
  if (o->script) {
    if (run_script(L, o) != LUA_OK)
      return 0;
  }
  else if (nothing_else) {
    if (isatty(STDIN_FILENO))
      run_prompt = 1;
    else if (dochunk(L, luaL_loadfile(L, NULL)) != LUA_OK)
      return 0;
  }
  if (run_prompt)
    prompt(L, o);

done:
  /* run this thread's messaging loop until all of its work is complete */
  if (rascal_push_complete(L) && report(L, docall(L, 0, 0)) != LUA_OK)
    return 0;
  lua_pushboolean(L, 1);
  return 1;
}


int main (int argc, char **argv) {
  Options o;
  lua_State *L;
  int status, success;

  memset(&o, 0, sizeof(o));
  o.argc = argc;
  o.argv = argv;
  if (!read_options(&o) || !build_paths(&o))
    return EXIT_FAILURE;

  L = luaL_newstate();
  if (L == NULL) {
    message("cannot create state: not enough memory");
    return EXIT_FAILURE;
  }
  lua_gc(L, LUA_GCSTOP);  /* stop the collector while starting up */
  lua_pushcfunction(L, pmain);
  lua_pushlightuserdata(L, &o);
  status = lua_pcall(L, 1, 1, 0);
  success = lua_toboolean(L, -1);
  report(L, status);
  lua_close(L);
  return (status == LUA_OK && success) ? EXIT_SUCCESS : EXIT_FAILURE;
}
