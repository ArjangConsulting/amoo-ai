SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: format lint check test coverage ci build swift-build plugin mod-check amoo-live amoo-live-debug verify-linux protos protos-check companion-ios-project companion-ios-protos companion-ios-build companion-android-build companion-build sample-app-compose-build sample-app-compose-test sample-apps-build e2e-ios e2e-android e2e-all docs

format:
	./scripts/ci/format.sh

lint:
	./scripts/ci/lint.sh

# One pre-commit gate: format (twice, see format.sh), then lint, then the Swift test suite.
# Does not build the companion apps — run `make companion-build` after touching CompanionApps/.
check: format lint test

test:
	@if [ -f Package.swift ]; then \
		swift test; \
	else \
		echo "No Package.swift found. Skipping tests."; \
	fi

coverage:
	./scripts/ci/test_coverage.sh

ci: lint coverage

build: swift-build companion-build

swift-build:
	swift build

# Rebuild the optimized binary at .build/release/amoo (the path an MCP client configured against a
# checkout points at) and print which build it now is. A stale one lacks every tool added since it
# was built, so run this after pulling.
release-local:
	swift build -c release --product amoo
	.build/release/amoo version

# Regenerate the client-specific agent files committed in plugins/amoo from its canonical
# agents/*.md. AmooPluginTests fails when they are stale.
plugin:
	swift run amoo agent render --out plugins/amoo

# Validate and test the Claude Code mod in plugins/amoo-live (its hooks module, state contract and
# pane). Needs the `claude` CLI; not part of `check`, since the Swift gate must not require it.
mod-check:
	@if ! command -v claude >/dev/null 2>&1; then echo "claude CLI not found; skipping mod-check."; exit 0; fi; \
	claude plugin validate plugins/amoo-live && claude plugin test plugins/amoo-live

# Start Claude Code with the amoo-live mod. `amoo-live` mirrors with the amoo on PATH (Homebrew);
# `amoo-live-debug` builds this checkout and mirrors with .build/debug/amoo. Pass claude flags in ARGS.
amoo-live:
	./scripts/amoo-live.sh $(ARGS)

amoo-live-debug:
	./scripts/amoo-live.sh --debug $(ARGS)

# Regenerate the committed host protobuf/gRPC Swift (Sources/Protos/Generated) from Protos/*.proto.
# Needed only after editing a .proto. Normal builds skip the generator plugin because it makes
# SwiftPM compile protoc from C++ source; see Package.swift and scripts/regenerate-protos.sh.
protos:
	./scripts/regenerate-protos.sh

# Fails when the committed generated files are stale (CI runs this in the Linux job).
protos-check:
	./scripts/regenerate-protos.sh --check

# Reproduce the CI "Build & Test (Linux)" job locally inside the swift:6.4-noble container.
# Needs Docker. Builds/tests into .build-linux/ so the host .build/ is untouched.
#   make verify-linux            # build + test (mirrors ci.yml)
#   ./scripts/verify-linux.sh build | test | shell
verify-linux:
	./scripts/verify-linux.sh ci

companion-ios-project:
	cd CompanionApps/iOS && xcodegen generate

companion-ios-protos:
	./CompanionApps/iOS/generate-protos.sh

companion-ios-build: companion-ios-protos companion-ios-project
	mkdir -p CompanionApps/iOS/build
	set -o pipefail; cd CompanionApps/iOS && xcodebuild build-for-testing \
		-project AmooCompanion.xcodeproj \
		-scheme AmooCompanion \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build 2>&1 | tee build/companion-ios-build.log
	python3 CompanionApps/iOS/sign-simulator-products.py CompanionApps/iOS/build/Build/Products

companion-android-build:
	@JDK="$$(./scripts/android-jdk.sh)"; \
	if [ -z "$$JDK" ]; then \
		echo "No JDK 17-26 found. AGP 9.3 / Gradle 9.5 requires a supported JDK."; \
		echo "Install with: brew install --cask temurin@21"; \
		exit 1; \
	fi; \
	echo "Using JAVA_HOME=$$JDK"; \
	cd CompanionApps/Android && JAVA_HOME="$$JDK" ./gradlew :app:assembleDebug :app:assembleAndroidTest

companion-build: companion-ios-build companion-android-build

# Fixture apps under test, one per UI toolkit. Deliberately separate targets rather than riding
# along in companion-android-build: each new toolkit would otherwise add to everyone's companion
# build time, with no way to iterate on one sample app alone.
sample-app-compose-build:
	@JDK="$$(./scripts/android-jdk.sh)"; \
	if [ -z "$$JDK" ]; then \
		echo "No JDK 17-26 found. Gradle 9.5 cannot run outside that range."; \
		echo "Install with: brew install --cask temurin@21"; \
		exit 1; \
	fi; \
	cd CompanionApps/Android && JAVA_HOME="$$JDK" ./gradlew :composeSampleApp:assembleDebug :composeSampleApp:assembleAndroidTest

sample-app-compose-test:
	@JDK="$$(./scripts/android-jdk.sh)"; \
	if [ -z "$$JDK" ]; then echo "No supported Android JDK found."; exit 1; fi; \
	cd CompanionApps/Android && JAVA_HOME="$$JDK" ./gradlew :composeSampleApp:connectedDebugAndroidTest

sample-apps-build: sample-app-compose-build

e2e-ios:
	bash ./scripts/run-e2e-ios.sh

e2e-android:
	bash ./scripts/run-e2e-android.sh

e2e-all:
	bash ./scripts/run-e2e-all.sh

docs:
	scripts/generate-docs.sh
