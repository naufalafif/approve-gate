# Your release keystore path goes in local.mk (not committed): AG_KEYSTORE := /path/to/release.jks
-include local.mk
export AG_KEYSTORE
APK := android/app/build/outputs/apk/release/app-release.apk

RULES := $(HOME)/.config/approve-gate/rules.json

# Hardened runtime: the settings helper only accepts this exact signed build as its caller.
build:
	swiftc -O mac/*.swift -o mac/approve
	codesign --force --sign - --options runtime mac/approve

test: build
	tests/run.sh

# Test build with its own config folder, for tests that pair a phone. Never install it.
test-build:
	swiftc -O -D APPROVE_TEST mac/*.swift -o mac/approve-test
	codesign --force --sign - --options runtime mac/approve-test
	swiftc -O tools/fakephone.swift -o tools/fakephone

# Pair, approve, deny, forged signature, no answer, unpair, over the real relay with the fake phone.
e2e: build test-build
	tests/e2e.sh

# One binary: ~/bin/approve. The wrapped CLIs are symlinks to it in ~/.local/bin/touchid-wrap,
# which wrapper-path.sh keeps first on PATH. Rules are copied once and then edited in place.
install: test
	@if [ -x /usr/local/libexec/approve-gate/approve ]; then \
	  echo "System mode is installed: update it with make system-install (make install would split the settings)."; exit 1; fi
	install -m 0755 mac/approve $(HOME)/bin/approve
	install -d -m 0700 $(HOME)/.config/approve-gate
	test -f $(RULES) || install -m 0600 mac/rules.example.json $(RULES)
	$(HOME)/bin/approve link

apk:
	cd android && AG_KEYSTORE_PASSWORD="$$(security find-generic-password -s approve-gate-keystore -w)" ./gradlew -q assembleRelease
	@echo $(APK)

phone: apk
	adb install -r $(APK)

# Same checks as the Security workflow.
scan:
	gitleaks git . --redact --no-banner
	semgrep scan --metrics=off --error --config p/kotlin --config p/java --config p/swift --config p/secrets --config p/github-actions
	d=$$(mktemp -d) && grep -E '^#|releaseRuntimeClasspath' android/app/gradle.lockfile > $$d/gradle.lockfile && osv-scanner scan source --lockfile $$d/gradle.lockfile
	actionlint .github/workflows/*.yml

# Menu bar status app: /Applications/Approve Gate Status.app
BAR_APP := menubar/Approve Gate Status.app
menubar:
	cd menubar && swift test && swift build -c release
	rm -rf "$(BAR_APP)" && mkdir -p "$(BAR_APP)/Contents/MacOS"
	cp menubar/.build/release/ApproveGateBar "$(BAR_APP)/Contents/MacOS/"
	cp menubar/Info.plist "$(BAR_APP)/Contents/"
	codesign --force --sign - "$(BAR_APP)"
	rm -rf "/Applications/Approve Gate Status.app" && cp -R "$(BAR_APP)" /Applications/
	-killall ApproveGateBar 2>/dev/null
	open "/Applications/Approve Gate Status.app"

# Root-owned install from this checkout (Homebrew users run `approve setup`). Asks for sudo once.
system-install: test
	mac/approve setup

# Signed APK to a GitHub release, for Obtainium. Bump versionName and versionCode first.
release:
	scripts/release.sh

.PHONY: build test test-build e2e install system-install menubar apk phone scan release
