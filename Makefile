SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.PHONY: format lint check test coverage ci build swift-build companion-ios-project companion-ios-protos companion-ios-build companion-android-build companion-build sample-app-compose-build sample-apps-build e2e-ios e2e-android e2e-all docs

format:
	./scripts/ci/format.sh

lint:
	./scripts/ci/lint.sh

# One pre-commit gate: format (twice, see format.sh), then lint, then the Swift test suite.
# Does not build the companion apps — run `make companion-build` after touching CompanionApps/.
check: format lint test

test:
	@if [ -f Package.swift ]; then \
		./scripts/with-protoc.sh swift test; \
	else \
		echo "No Package.swift found. Skipping tests."; \
	fi

coverage:
	./scripts/ci/test_coverage.sh

ci: lint coverage

build: swift-build companion-build

swift-build:
	./scripts/with-protoc.sh swift build

companion-ios-project:
	cd CompanionApps/iOS && xcodegen generate

companion-ios-protos:
	./CompanionApps/iOS/generate-protos.sh

companion-ios-build: companion-ios-protos companion-ios-project
	cd CompanionApps/iOS && xcodebuild build-for-testing \
		-project AmooCompanion.xcodeproj \
		-scheme AmooCompanion \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build 2>&1 | tail -5

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
	cd CompanionApps/Android && JAVA_HOME="$$JDK" ./gradlew :composeSampleApp:assembleDebug

sample-apps-build: sample-app-compose-build

e2e-ios:
	bash ./scripts/run-e2e-ios.sh

e2e-android:
	bash ./scripts/run-e2e-android.sh

e2e-all:
	bash ./scripts/run-e2e-all.sh

docs:
	./scripts/with-protoc.sh scripts/generate-docs.sh
