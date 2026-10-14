# ZeroMQ (libzmq) — C++, so built with its own configure script into a
# static library rather than by the generic dependency rules
DEPS += zeromq
zeromq_VERSION := 4.3.5
zeromq_HOME    := https://zeromq.org
zeromq_URL     := https://github.com/zeromq/libzmq/releases/download/v$(zeromq_VERSION)/zeromq-$(zeromq_VERSION).tar.gz
zeromq_SHA256  := 6653ef5910f17954861fe72332e68b03ca6e4d9c7160eb3a8de5a5a913bfab43
zeromq_LICENSE := LICENSE

zeromq_INCLUDES := -I$(SRC)/zeromq/include
zeromq_LIB := $(BUILD)/zeromq/libzmq.a

# no optional extras: anything auto-detected here would become a dynamic
# dependency of the final executable. CURVE uses the bundled tweetnacl.
zeromq_CONFIGURE := \
	--enable-static --disable-shared \
	--without-docs --disable-Werror --disable-drafts \
	--disable-perf --disable-curve-keygen \
	--disable-libunwind --disable-libbsd \
	--without-libsodium --without-libgssapi_krb5 \
	--without-pgm --without-norm --without-vmci

$(zeromq_LIB): $(call stamp,zeromq)
	@echo "  BUILD zeromq $(zeromq_VERSION) (log: $(BUILD)/zeromq/build.log)"
	@mkdir -p $(@D)
	@cd $(SRC)/zeromq && ./configure $(zeromq_CONFIGURE) \
		CC="$(CC)" CXX="$(CXX)" CFLAGS="$(BASE_CFLAGS)" CXXFLAGS="$(BASE_CFLAGS)" \
		> $(CURDIR)/$(BUILD)/zeromq/build.log 2>&1 \
		|| { tail -40 $(CURDIR)/$(BUILD)/zeromq/build.log; exit 1; }
	@$(MAKE) -C $(SRC)/zeromq src/libzmq.la >> $(BUILD)/zeromq/build.log 2>&1 \
		|| { tail -40 $(BUILD)/zeromq/build.log; exit 1; }
	@cp $(SRC)/zeromq/src/.libs/libzmq.a $@
