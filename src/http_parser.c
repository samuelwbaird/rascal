/*
** require 'rascal.http.parser' — parsing HTTP requests and responses with
** picohttpparser
**
**   parser.parse_request(buffer)
**     nil                          the request is not yet complete
**     false, reason                the request is invalid
**     request, header_length       { method, path, version, headers }
**
**   parser.parse_response(buffer)
**     as above, with { status, message, version, headers }
**
** Header names are lower case. A header given more than once has its values
** joined, with '; ' for cookie and ', ' otherwise. The body, if any, starts
** after header_length bytes.
*/

#include <ctype.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "picohttpparser.h"

#define MAX_HEADERS 100


/* push a table of headers by lower case name */
static void push_headers (lua_State *L, struct phr_header *headers, size_t count) {
  size_t i, j;
  lua_createtable(L, 0, (int)count);
  for (i = 0; i < count; i++) {
    luaL_Buffer name;
    luaL_buffinit(L, &name);
    for (j = 0; j < headers[i].name_len; j++)
      luaL_addchar(&name, tolower((unsigned char)headers[i].name[j]));
    luaL_pushresult(&name);
    /* a header given again is joined to the earlier value */
    lua_pushvalue(L, -1);
    if (lua_rawget(L, -3) != LUA_TNIL) {
      const char *separator = strcmp(lua_tostring(L, -2), "cookie") == 0 ? "; " : ", ";
      lua_pushstring(L, separator);
      lua_pushlstring(L, headers[i].value, headers[i].value_len);
      lua_concat(L, 3);
    }
    else {
      lua_pop(L, 1);
      lua_pushlstring(L, headers[i].value, headers[i].value_len);
    }
    lua_rawset(L, -3);
  }
}


static void push_version (lua_State *L, int minor_version) {
  lua_pushfstring(L, "1.%d", minor_version);
}


static int incomplete_or_invalid (lua_State *L, int result, const char *what) {
  if (result == -2) {
    lua_pushnil(L);
    return 1;
  }
  lua_pushboolean(L, 0);
  lua_pushfstring(L, "invalid %s", what);
  return 2;
}


static int parse_request (lua_State *L) {
  size_t length, method_length, path_length, header_count = MAX_HEADERS;
  const char *buffer = luaL_checklstring(L, 1, &length);
  const char *method, *path;
  int minor_version;
  struct phr_header headers[MAX_HEADERS];

  int result = phr_parse_request(buffer, length, &method, &method_length, &path, &path_length,
                                 &minor_version, headers, &header_count, 0);
  if (result < 0)
    return incomplete_or_invalid(L, result, "request");

  lua_createtable(L, 0, 4);
  lua_pushlstring(L, method, method_length);
  lua_setfield(L, -2, "method");
  lua_pushlstring(L, path, path_length);
  lua_setfield(L, -2, "path");
  push_version(L, minor_version);
  lua_setfield(L, -2, "version");
  push_headers(L, headers, header_count);
  lua_setfield(L, -2, "headers");
  lua_pushinteger(L, result);
  return 2;
}


static int parse_response (lua_State *L) {
  size_t length, message_length, header_count = MAX_HEADERS;
  const char *buffer = luaL_checklstring(L, 1, &length);
  const char *message;
  int minor_version, status;
  struct phr_header headers[MAX_HEADERS];

  int result = phr_parse_response(buffer, length, &minor_version, &status, &message, &message_length,
                                  headers, &header_count, 0);
  if (result < 0)
    return incomplete_or_invalid(L, result, "response");

  lua_createtable(L, 0, 4);
  lua_pushinteger(L, status);
  lua_setfield(L, -2, "status");
  lua_pushlstring(L, message, message_length);
  lua_setfield(L, -2, "message");
  push_version(L, minor_version);
  lua_setfield(L, -2, "version");
  push_headers(L, headers, header_count);
  lua_setfield(L, -2, "headers");
  lua_pushinteger(L, result);
  return 2;
}


int luaopen_rascal_http_parser (lua_State *L) {
  static const luaL_Reg functions[] = {
    { "parse_request", parse_request },
    { "parse_response", parse_response },
    { NULL, NULL }
  };
  luaL_newlib(L, functions);
  return 1;
}
