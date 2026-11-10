# linenoise — line editing and history for rascal's interactive prompt,
# used directly by src/main.c rather than as a Lua module
DEPS += linenoise
linenoise_VERSION := 2.0
linenoise_HOME    := https://github.com/antirez/linenoise
linenoise_URL     := https://github.com/antirez/linenoise/archive/refs/tags/$(linenoise_VERSION).tar.gz
linenoise_SHA256  := 97ad7d4041e11d7fa395819fd773c1892dea89e5292342378a8345692ce89c29
linenoise_LICENSE := LICENSE

linenoise_SRCS := linenoise.c
linenoise_INCLUDES := -I$(SRC)/linenoise
