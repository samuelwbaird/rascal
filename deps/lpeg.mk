# LPeg — require 'lpeg', and its re module, require 're'
DEPS += lpeg
lpeg_VERSION := 1.1.0
lpeg_HOME    := https://www.inf.puc-rio.br/~roberto/lpeg/
lpeg_URL     := https://www.inf.puc-rio.br/~roberto/lpeg/lpeg-$(lpeg_VERSION).tar.gz
lpeg_SHA256  := 4b155d67d2246c1ffa7ad7bc466c1ea899bbc40fef0257cc9c03cecbaed4352a
# the licence is in the html documentation
lpeg_LICENSE := lpeg.html
lpeg_LICENSE_LINES := 1391,1420

lpeg_SRCS := lpcap.c lpcode.c lpcset.c lpprint.c lptree.c lpvm.c
lpeg_CMODULES := lpeg:luaopen_lpeg
lpeg_LUA := re:re.lua
