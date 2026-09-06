PACKAGE := hypr-sticky-hdr

prefix ?= /usr/local
datarootdir ?= $(prefix)/share
LUA ?= $(shell command -v lua 2>/dev/null || command -v lua5.4 2>/dev/null)
LUA_VERSION ?= $(shell $(LUA) -e 'io.write((_VERSION:gsub("^Lua%s+", "")))' 2>/dev/null)
luadir ?= $(datarootdir)/lua/$(LUA_VERSION)
moduledir ?= $(luadir)/hypr
docdir ?= $(datarootdir)/doc/$(PACKAGE)
licensedir ?= $(datarootdir)/licenses/$(PACKAGE)

INSTALL ?= install
INSTALL_DATA ?= $(INSTALL) -m 644
RM ?= rm -f

USER_CONFIG_HOME := $(or $(strip $(XDG_CONFIG_HOME)),$(HOME)/.config)
USER_MODULE_DIR := $(USER_CONFIG_HOME)/hypr

override PROJECT_ROOT := $(realpath $(CURDIR))
override DIST_ROOT := $(PROJECT_ROOT)/dist
override DIST_NAME := hypr-sticky-hdr-$(VERSION)
override DIST_STAGE := $(DIST_ROOT)/$(DIST_NAME)
override DIST_ARCHIVE := $(DIST_ROOT)/$(DIST_NAME).tar.gz
override DIST_CHECKSUM := $(DIST_ARCHIVE).sha256
DIST_FILES := Makefile sticky_hdr.lua README.md LICENSE tests/hl_mock.lua tests/run.sh tests/test.lua
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || printf 0)

.PHONY: all check install-user uninstall-user install uninstall dist distcheck clean \
	validate-lua-version validate-version validate-dist-root validate-dist-path

all: check

check:
	./tests/run.sh

install-user:
	$(INSTALL) -d "$(USER_MODULE_DIR)"
	$(INSTALL_DATA) sticky_hdr.lua "$(USER_MODULE_DIR)/sticky_hdr.lua"

uninstall-user:
	$(RM) "$(USER_MODULE_DIR)/sticky_hdr.lua"

install: validate-lua-version
	$(INSTALL) -d "$(DESTDIR)$(moduledir)" "$(DESTDIR)$(docdir)" "$(DESTDIR)$(licensedir)"
	$(INSTALL_DATA) sticky_hdr.lua "$(DESTDIR)$(moduledir)/sticky_hdr.lua"
	$(INSTALL_DATA) README.md "$(DESTDIR)$(docdir)/README.md"
	$(INSTALL_DATA) LICENSE "$(DESTDIR)$(licensedir)/LICENSE"

uninstall: validate-lua-version
	$(RM) "$(DESTDIR)$(moduledir)/sticky_hdr.lua"
	$(RM) "$(DESTDIR)$(docdir)/README.md"
	$(RM) "$(DESTDIR)$(licensedir)/LICENSE"

validate-version:
	@printf '%s\n' "$(VERSION)" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || \
		{ printf '%s\n' 'VERSION must be numeric SemVer (for example, 1.2.3)' >&2; exit 2; }

validate-lua-version:
	@printf '%s\n' "$(LUA_VERSION)" | grep -Eq '^[0-9]+\.[0-9]+$$' || \
		{ printf '%s\n' 'LUA_VERSION must be major.minor; set LUA or LUA_VERSION explicitly' >&2; exit 2; }

validate-dist-root:
	@test "$(DIST_ROOT)" = "$(PROJECT_ROOT)/dist" || \
		{ printf '%s\n' 'refusing unsafe DIST_ROOT' >&2; exit 2; }

validate-dist-path: validate-version validate-dist-root
	@test "$(DIST_STAGE)" = "$(DIST_ROOT)/hypr-sticky-hdr-$(VERSION)" || \
		{ printf '%s\n' 'refusing unsafe DIST_STAGE' >&2; exit 2; }

dist: validate-dist-path
	rm -rf -- "$(DIST_STAGE)"
	mkdir -p "$(DIST_STAGE)/tests"
	cp --parents $(DIST_FILES) "$(DIST_STAGE)"
	tar --sort=name --mtime="@$(SOURCE_DATE_EPOCH)" --owner=0 --group=0 --numeric-owner \
		-C "$(DIST_ROOT)" -czf "$(DIST_ARCHIVE)" "$(DIST_NAME)"
	rm -rf -- "$(DIST_STAGE)"
	cd "$(DIST_ROOT)" && sha256sum "$(DIST_NAME).tar.gz" > "$(DIST_NAME).tar.gz.sha256"

distcheck: dist
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		cd "$(DIST_ROOT)"; sha256sum -c "$(DIST_NAME).tar.gz.sha256"; cd - >/dev/null; \
		tar -xzf "$(DIST_ARCHIVE)" -C "$$tmp"; \
		$(MAKE) -C "$$tmp/$(DIST_NAME)" check; \
		$(MAKE) -C "$$tmp/$(DIST_NAME)" DESTDIR="$$tmp/pkg" prefix=/usr install; \
		cmp sticky_hdr.lua "$$tmp/pkg/usr/share/lua/$(LUA_VERSION)/hypr/sticky_hdr.lua"; \
		cmp README.md "$$tmp/pkg/usr/share/doc/$(PACKAGE)/README.md"; \
		cmp LICENSE "$$tmp/pkg/usr/share/licenses/$(PACKAGE)/LICENSE"; \
		test "$$(find "$$tmp/pkg" -type f -printf '%P\n' | LC_ALL=C sort)" = \
		"$$(printf '%s\n' \
			'usr/share/doc/$(PACKAGE)/README.md' \
			'usr/share/licenses/$(PACKAGE)/LICENSE' \
			'usr/share/lua/$(LUA_VERSION)/hypr/sticky_hdr.lua')"; \
		$(MAKE) -C "$$tmp/$(DIST_NAME)" DESTDIR="$$tmp/pkg" prefix=/usr uninstall; \
		test -z "$$(find "$$tmp/pkg" -type f -print -quit)"

clean: validate-dist-root
	rm -rf -- "$(DIST_ROOT)"
