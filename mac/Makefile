PROJECT := zshell.xcodeproj
SCHEME := zshell
CONFIGURATION := Debug
ARCH ?= $(shell uname -m)
DERIVED_DATA := $(CURDIR)/build/debug
DEBUG_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/zshell Debug.app
DEBUG_BUNDLE_ID := sh.zshell.dev

# Sparkle's release tools used to arrive with the SPM artifact Xcode unpacked
# into DerivedData. The framework is a repo-local binary target now, so point
# the release scripts at the copy vendored beside it.
SPARKLE_BIN ?= $(CURDIR)/Vendor/Sparkle/bin
export SPARKLE_BIN
# SwiftPM manifest evaluation, Swift macro expansion, and user script phases
# each nest a sandbox-exec profile under xcodebuild. Inside another seatbelt
# sandbox (agent shells, CI runners, Homebrew) macOS rejects the nested
# sandbox_apply with EPERM and the build dies with a confusing "Could not
# resolve package dependencies" error. Probe for that case and let xcodebuild
# skip the nested sandboxes via its supported settings; on normal machines
# the probe passes, the variable stays empty, and nothing changes.
SANDBOX_PROBE_EXIT := $(shell /usr/bin/sandbox-exec -p '(version 1)(deny default)(allow file-read*)' /usr/bin/true >/dev/null 2>&1; echo $$?)
ifneq ($(SANDBOX_PROBE_EXIT),0)
XCODEBUILD_NESTED_SANDBOX_FLAGS := \
ENABLE_USER_SCRIPT_SANDBOXING=NO \
OTHER_SWIFT_FLAGS='$$(inherited) -disable-sandbox' \
-IDEPackageSupportDisableManifestSandbox=1
endif

ifdef DEVELOPER_DIR
XCODEBUILD := DEVELOPER_DIR="$(DEVELOPER_DIR)" xcodebuild
else
XCODEBUILD := xcodebuild
endif

# A stable DerivedData path lets `open` address the Debug bundle directly.
run:
	@$(XCODEBUILD) -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -destination 'platform=macOS,arch=$(ARCH)' $(XCODEBUILD_NESTED_SANDBOX_FLAGS)
	# Zshell-hosted shells export these for the in-app CLI; inheriting them makes
	# the Debug bundle immediately act as that CLI instead of launching its UI.
	@/usr/bin/env -u ZSHELL_CLI_STATE -u ZSHELL_CLI_TOKEN /usr/bin/open -n "$(DEBUG_APP)"

update:
	@$(MAKE) stop
	@$(MAKE) run

# Give terminal sessions their normal shutdown path before forcing a stuck Debug app.
stop:
	@osascript -l JavaScript -e 'ObjC.import("AppKit"); const apps = $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("$(DEBUG_BUNDLE_ID)"); for (let i = 0; i < apps.count; i += 1) { void apps.objectAtIndex(i).terminate; }'
	@sleep 1
	@osascript -l JavaScript -e 'ObjC.import("AppKit"); const apps = $$.NSRunningApplication.runningApplicationsWithBundleIdentifier("$(DEBUG_BUNDLE_ID)"); for (let i = 0; i < apps.count; i += 1) { void apps.objectAtIndex(i).forceTerminate; }'

# `--local` builds all three signed architecture packages and feeds without publishing.
build-package:
	@bun scripts/release.ts --local

clean: stop
	@rm -rf build Vendor/alacritty-bridge/target
