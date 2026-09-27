NAME := google-play-books-downloader
BUNDLE_ID := cc.1905.$(NAME)
BIN := .build/release/$(NAME)
APP := .build/$(NAME).app
APPNAME := $(notdir $(APP))
APPDIR ?= /Applications
PREFIX ?= $(HOME)/.local
CLI := $(PREFIX)/bin/$(NAME)
# Pre-rename install (Screenshoter), moved to /tmp/trash by `make install` / `make uninstall`.
OLD_APP := $(APPDIR)/Screenshoter.app
OLD_CLI := $(PREFIX)/bin/screenshoter
TRASH = (mkdir -p /tmp/trash && mv $(1) /tmp/trash/$(notdir $(1)).$$(date +%Y%m%d-%H%M%S))
ICON := Resources/AppIcon.icns

.PHONY: run build test app icon install uninstall dmg

run: build
	$(BIN) $(ARGS)

build:
	swift build -c release

test:
	swift test

# $(NAME).app: the release binary + Info.plist + icon. Ad-hoc signed with an explicit
# designated requirement on the bundle id: plain ad-hoc pins TCC grants (Screen Recording,
# Accessibility) to the build's cdhash, so every rebuild silently lost them.
app: build $(ICON)
	@[ ! -e $(APP) ] || $(call TRASH,$(APP))
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/$(NAME)
	cp Info.plist $(APP)/Contents/Info.plist
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - -r='designated => identifier "$(BUNDLE_ID)"' $(APP)

# Icon: drawn by tools/make_icon.swift, then packed into an .icns with every size macOS wants.
icon: $(ICON)
$(ICON): tools/make_icon.swift
	@mkdir -p Resources .build/AppIcon.iconset
	swift tools/make_icon.swift .build/icon_1024.png
	@for s in 16 32 128 256 512; do \
		sips -z $$s $$s .build/icon_1024.png --out .build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		d=$$((s*2)); sips -z $$d $$d .build/icon_1024.png --out .build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns .build/AppIcon.iconset -o $(ICON)

# App to /Applications (Launchpad, Spotlight) + `$(NAME)` CLI linked to it.
# Also moves the pre-rename Screenshoter.app and `screenshoter` link to /tmp/trash.
install: app
	@mkdir -p /tmp/trash
	@[ ! -e $(OLD_APP) ] || $(call TRASH,$(OLD_APP))
	@[ ! -e $(OLD_CLI) ] && [ ! -L $(OLD_CLI) ] || $(call TRASH,$(OLD_CLI))
	@[ ! -e $(APPDIR)/$(APPNAME) ] || $(call TRASH,$(APPDIR)/$(APPNAME))
	cp -R $(APP) $(APPDIR)/
	install -d $(PREFIX)/bin
	@[ ! -e $(CLI) ] && [ ! -L $(CLI) ] || $(call TRASH,$(CLI))
	ln -s $(APPDIR)/$(APPNAME)/Contents/MacOS/$(NAME) $(CLI)
	@echo "installed $(APPDIR)/$(APPNAME) and $(CLI)"

# Moves everything (also the pre-rename install) to /tmp/trash instead of deleting it.
uninstall:
	@mkdir -p /tmp/trash
	@[ ! -e $(APPDIR)/$(APPNAME) ] || $(call TRASH,$(APPDIR)/$(APPNAME))
	@[ ! -e $(CLI) ] && [ ! -L $(CLI) ] || $(call TRASH,$(CLI))
	@[ ! -e $(OLD_APP) ] || $(call TRASH,$(OLD_APP))
	@[ ! -e $(OLD_CLI) ] && [ ! -L $(OLD_CLI) ] || $(call TRASH,$(OLD_CLI))
	@echo "uninstalled (moved to /tmp/trash)"

# Release disk image: the app plus an /Applications link, compressed (UDZO).
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
DMG := .build/$(NAME)-$(VERSION).dmg
dmg: app
	@mkdir -p /tmp/trash .build/dmg-root
	@[ ! -e $(DMG) ] || $(call TRASH,$(DMG))
	@[ ! -e .build/dmg-root/$(APPNAME) ] || $(call TRASH,.build/dmg-root/$(APPNAME))
	cp -R $(APP) .build/dmg-root/
	@[ -L .build/dmg-root/Applications ] || ln -s /Applications .build/dmg-root/Applications
	hdiutil create -volname "Google Play Books Downloader" -srcfolder .build/dmg-root -ov -format UDZO $(DMG)
	@echo "built $(DMG)"
