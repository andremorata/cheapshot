APP := build/cheapshot.app
# Ad-hoc by default. A stable identity keeps the Screen Recording grant across rebuilds.
# Set yours in local.mk, which git ignores: CODESIGN_IDENTITY := cheapshot dev
-include local.mk
CODESIGN_IDENTITY ?= -
# The version comes from the latest git tag, so tags are the only place it is written.
# The release workflow passes the next one in.
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
BUILD_NUMBER ?= $(shell git rev-list --count HEAD 2>/dev/null)

.PHONY: app run test snapshots icon clean

app:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release --show-bin-path)/cheapshot" $(APP)/Contents/MacOS/cheapshot
	cp Support/Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(or $(VERSION),0.0.0)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(or $(BUILD_NUMBER),1)" $(APP)/Contents/Info.plist
	cp Support/AppIcon.icns Support/MenuBarIcon.svg $(APP)/Contents/Resources/
# The hardened runtime stops other programs from loading code into cheapshot to borrow its permissions.
	codesign --force --options runtime --entitlements Support/cheapshot.entitlements --sign "$(CODESIGN_IDENTITY)" $(APP)

run: app
	open $(APP)

# The Command Line Tools ship the Swift Testing macros outside the default plugin path.
# Xcode finds them without help, and the extra path is harmless there.
TESTING_PLUGINS := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

test:
	swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)

# Renders the editor and settings windows to build/snapshots without showing them on screen.
snapshots:
	CHEAPSHOT_SNAPSHOTS=$(CURDIR)/build/snapshots swift test -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS) --filter Snapshot

# Rebuilds Support/AppIcon.icns from Support/AppIcon.svg. Run it after editing the SVG.
icon:
	rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
	swift Support/render-icon.swift Support/AppIcon.svg build/AppIcon-1024.png 1024
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/AppIcon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) build/AppIcon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Support/AppIcon.icns

clean:
	rm -rf .build build
