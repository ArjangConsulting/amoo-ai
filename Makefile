.PHONY: format lint test coverage ci build swift-build companion-ios-project companion-ios-protos companion-ios-build companion-android-build companion-build e2e-ios e2e-android e2e-all

format:
	./scripts/ci/format.sh

lint:
	./scripts/ci/lint.sh

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

companion-ios-build: companion-ios-project
	cd CompanionApps/iOS && xcodebuild build-for-testing \
		-project MobileTestingCompanion.xcodeproj \
		-scheme MobileTestingCompanion \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build 2>&1 | tail -5

companion-android-build:
	cd CompanionApps/Android && ./gradlew assembleDebug assembleAndroidTest

companion-build: companion-ios-build companion-android-build

e2e-ios:
	bash ./scripts/run-e2e-ios.sh

e2e-android:
	bash ./scripts/run-e2e-android.sh

e2e-all:
	bash ./scripts/run-e2e-all.sh
