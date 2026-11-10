# libsodium — password hashing and encryption for rascal.crypto, through its
# own binding in src/sodium.c (require 'rascal.crypto.sodium'). Built with
# its own configure script, as it chooses CPU specific flags for some sources,
# and with --enable-minimal, which keeps the high level functions rascal uses
DEPS += libsodium
libsodium_VERSION := 1.0.22
libsodium_HOME    := https://libsodium.org
libsodium_URL     := https://download.libsodium.org/libsodium/releases/libsodium-$(libsodium_VERSION).tar.gz
libsodium_SHA256  := adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349
libsodium_LICENSE := LICENSE

libsodium_INCLUDES := -I$(SRC)/libsodium/src/libsodium/include
libsodium_LIB := $(BUILD)/libsodium/libsodium.a
libsodium_CMODULES := rascal.crypto.sodium:luaopen_rascal_crypto_sodium

libsodium_CONFIGURE := --enable-static --disable-shared --enable-minimal --disable-dependency-tracking

$(libsodium_LIB): $(call stamp,libsodium) config.mk deps/libsodium.mk
	@echo "  BUILD libsodium $(libsodium_VERSION) (log: $(BUILD)/libsodium/build.log)"
	@mkdir -p $(@D)
	@cd $(SRC)/libsodium && ./configure $(libsodium_CONFIGURE) \
		CC="$(CC)" CFLAGS="$(BASE_CFLAGS)" \
		> $(CURDIR)/$(BUILD)/libsodium/build.log 2>&1 \
		|| { tail -40 $(CURDIR)/$(BUILD)/libsodium/build.log; exit 1; }
	@$(MAKE) -C $(SRC)/libsodium/src/libsodium libsodium.la >> $(BUILD)/libsodium/build.log 2>&1 \
		|| { tail -40 $(BUILD)/libsodium/build.log; exit 1; }
	@cp $(SRC)/libsodium/src/libsodium/.libs/libsodium.a $@

# configure generates sodium/version.h, which the binding includes
$(OBJ)/rascal/sodium.o: $(libsodium_LIB)
