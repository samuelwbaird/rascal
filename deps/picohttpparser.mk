# picohttpparser — HTTP request and response parsing, used by rascal.http
# through its own binding in src/http_parser.c (require 'rascal.http.parser')
DEPS += picohttpparser
picohttpparser_VERSION := 1.4-465a7ff
picohttpparser_HOME    := https://github.com/h2o/picohttpparser
picohttpparser_URL     := https://github.com/h2o/picohttpparser/archive/465a7ff09fbd3432fe56c673451f5460154d1f07.tar.gz
picohttpparser_SHA256  := d65d80b362fcb11f6e982ebc4515442d93b937b166558120031c38a8b6c173cd
picohttpparser_LICENSE := picohttpparser.h
picohttpparser_LICENSE_LINES := 1,25

picohttpparser_SRCS := picohttpparser.c
picohttpparser_INCLUDES := -I$(SRC)/picohttpparser
picohttpparser_CMODULES := rascal.http.parser:luaopen_rascal_http_parser
