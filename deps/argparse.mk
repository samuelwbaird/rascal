# argparse — require 'argparse', pure Lua
DEPS += argparse
argparse_VERSION := 0.7.1
argparse_HOME    := https://github.com/luarocks/argparse
argparse_URL     := https://github.com/luarocks/argparse/archive/refs/tags/$(argparse_VERSION).tar.gz
argparse_SHA256  := d344e49404c3e7b3e7fa4fe6741c106f25909d9b24923cb08dcceda1f9754809
argparse_LICENSE := LICENSE

argparse_LUA := argparse:src/argparse.lua
