# Thin wrappers around xcodebuild / swift so everything can be driven from the terminal.
# SDKROOT is pinned because a stale Command Line Tools install can otherwise win the SDK lookup.
export SDKROOT := macosx

PROJECT   := AppleMusicPresence.xcodeproj
SCHEME    := AppleMusicPresence
APP_NAME  := Apple Music Presence.app
BUILD_DIR := .build/xcode
LOG_SUBSYSTEM := dev.dta32.applemusicpresence

.PHONY: build release run install uninstall test test-live logs footprint clean quit

# Quit a running copy and wait until it is gone; `open` on a still-exiting app reuses the dying process.
quit:
	@pkill -x "Apple Music Presence" || true
	@while pgrep -x "Apple Music Presence" >/dev/null; do sleep 0.2; done

build:            ## Debug build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) -quiet build

release:          ## Release build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(BUILD_DIR) -quiet build

run: build quit   ## Build (Debug) and launch, replacing any running copy
	open "$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME)"

install: release quit  ## Release build copied to /Applications and launched
	rm -rf "/Applications/$(APP_NAME)"
	ditto "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME)" "/Applications/$(APP_NAME)"
	open "/Applications/$(APP_NAME)"

uninstall: quit
	rm -rf "/Applications/$(APP_NAME)"

test:             ## Unit tests for the logic package
	cd Packages/AMPKit && swift test

test-live:        ## Talks to the running Discord app and the real iTunes Search API
	cd Packages/AMPKit && AMP_LIVE_DISCORD=1 AMP_LIVE_NETWORK=1 swift test --filter 'Live'

logs:             ## Stream the app's logs
	log stream --level info --predicate 'subsystem == "$(LOG_SUBSYSTEM)"'

footprint:        ## Memory as Activity Monitor reports it
	footprint -p "$$(pgrep -x 'Apple Music Presence')" | grep -E 'Footprint|phys_footprint'

clean:
	rm -rf $(BUILD_DIR)
