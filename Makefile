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
DIST_FILES := Makefile sticky_hdr.lua README.md LICENSE packaging/aur/PKGBUILD \
	tests/hl_mock.lua tests/run.sh tests/test.lua
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || printf 0)
PKGREL ?= 1
override AUR_TEMPLATE := $(PROJECT_ROOT)/packaging/aur/PKGBUILD
override AUR_DIR := $(DIST_ROOT)/aur
override AUR_PKGBUILD := $(AUR_DIR)/PKGBUILD

.PHONY: all check install-user uninstall-user install uninstall dist distcheck pkgbuild clean \
	validate-lua-version validate-version validate-pkgrel validate-dist-root validate-dist-path

all: check

check:
	LUA="$(LUA)" ./tests/run.sh

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
	@test ! -L "$(DIST_ROOT)" || \
		{ printf '%s\n' 'refusing symlinked DIST_ROOT' >&2; exit 2; }

validate-dist-path: validate-version validate-dist-root
	@test "$(DIST_STAGE)" = "$(DIST_ROOT)/hypr-sticky-hdr-$(VERSION)" || \
		{ printf '%s\n' 'refusing unsafe DIST_STAGE' >&2; exit 2; }

validate-pkgrel:
	@printf '%s\n' "$(PKGREL)" | grep -Eq '^[1-9][0-9]*$$' || \
		{ printf '%s\n' 'PKGREL must be a positive integer' >&2; exit 2; }

# Render the AUR recipe from an existing dist/<name>.tar.gz.sha256 (from
# `make dist`, or the published release checksum) so the release flow pins the
# archive it shipped rather than a rebuild. Does not depend on `dist` on purpose.
pkgbuild: validate-dist-path validate-pkgrel
	@set -eu; \
		test -f "$(DIST_CHECKSUM)" || { printf '%s\n' \
			"missing $(DIST_CHECKSUM): run 'make dist VERSION=$(VERSION)' or place the release .sha256 in dist/" >&2; exit 2; }; \
		sum=$$(cut -d' ' -f1 -- "$(DIST_CHECKSUM)"); \
		printf '%s\n' "$$sum" | grep -Eq '^[0-9a-f]{64}$$' || \
			{ printf '%s\n' "invalid checksum in $(DIST_CHECKSUM)" >&2; exit 2; }; \
		mkdir -p "$(AUR_DIR)"; \
		sed -e 's/@VERSION@/$(VERSION)/g' -e 's/@PKGREL@/$(PKGREL)/g' -e "s/@SHA256@/$$sum/g" \
			"$(AUR_TEMPLATE)" > "$(AUR_PKGBUILD).tmp"; \
		! grep -En '@[A-Z0-9_]+@' "$(AUR_PKGBUILD).tmp" || \
			{ printf '%s\n' 'unrendered placeholder in PKGBUILD' >&2; rm -f "$(AUR_PKGBUILD).tmp"; exit 2; }; \
		mv -f "$(AUR_PKGBUILD).tmp" "$(AUR_PKGBUILD)"; \
		printf '%s\n' "$(AUR_PKGBUILD)"

dist: validate-dist-path
	rm -rf -- "$(DIST_STAGE)"
	mkdir -p "$(DIST_STAGE)/tests"
	cp --parents $(DIST_FILES) "$(DIST_STAGE)"
	tar --sort=name --mtime="@$(SOURCE_DATE_EPOCH)" --owner=0 --group=0 --numeric-owner \
		--mode='u=rwX,go=rX' \
		-C "$(DIST_ROOT)" --use-compress-program='gzip -n' \
		-cf "$(DIST_ARCHIVE)" "$(DIST_NAME)"
	rm -rf -- "$(DIST_STAGE)"
	cd "$(DIST_ROOT)" && sha256sum "$(DIST_NAME).tar.gz" > "$(DIST_NAME).tar.gz.sha256"

distcheck: dist
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		cd "$(DIST_ROOT)"; sha256sum -c "$(DIST_NAME).tar.gz.sha256"; cd - >/dev/null; \
		tar -xzf "$(DIST_ARCHIVE)" -C "$$tmp"; \
		src="$$tmp/$(DIST_NAME)"; \
		$(MAKE) -C "$$src" check; \
		$(MAKE) -C "$$src" DESTDIR="$$tmp/pkg" prefix=/usr install; \
		cmp "$$src/sticky_hdr.lua" "$$tmp/pkg/usr/share/lua/$(LUA_VERSION)/hypr/sticky_hdr.lua"; \
		cmp "$$src/README.md" "$$tmp/pkg/usr/share/doc/$(PACKAGE)/README.md"; \
		cmp "$$src/LICENSE" "$$tmp/pkg/usr/share/licenses/$(PACKAGE)/LICENSE"; \
		test "$$(find "$$tmp/pkg" -type f -printf '%P\n' | LC_ALL=C sort)" = \
		"$$(printf '%s\n' \
			'usr/share/doc/$(PACKAGE)/README.md' \
			'usr/share/licenses/$(PACKAGE)/LICENSE' \
			'usr/share/lua/$(LUA_VERSION)/hypr/sticky_hdr.lua')"; \
		$(MAKE) -C "$$src" DESTDIR="$$tmp/pkg" prefix=/usr uninstall; \
		test -z "$$(find "$$tmp/pkg" -type f -print -quit)"; \
		$(MAKE) --no-print-directory pkgbuild VERSION="$(VERSION)"; \
		bash -n "$(AUR_PKGBUILD)"

clean: validate-dist-root
	rm -rf -- "$(DIST_ROOT)"
