#!/bin/bash
# Build relocatable companions for release archives; never boot a CI simulator.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-all}" != android ]]; then
  "$root/CompanionApps/iOS/generate-protos.sh"
  (cd "$root/CompanionApps/iOS" && xcodegen generate)
  for platform in iphonesimulator iphoneos; do
    destination='generic/platform=iOS Simulator'
    architectures='arm64 x86_64'
    if [[ "$platform" == iphoneos ]]; then
      destination='generic/platform=iOS'
      architectures='arm64'
    fi
    xcodebuild build-for-testing \
      -project "$root/CompanionApps/iOS/AmooCompanion.xcodeproj" \
      -scheme AmooCompanion -destination "$destination" \
      -derivedDataPath "$root/.build-companion-release/$platform" \
      CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO "ARCHS=$architectures"
    target="$root/CompanionApps/iOS/prebuilt/$platform"
    mkdir -p "$target"
    rm -rf "$target/Products"
    cp -R "$root/.build-companion-release/$platform/Build/Products" "$target/Products"
    if [[ "$platform" == iphonesimulator ]]; then
      python3 "$root/scripts/sign-simulator-products.py" "$target/Products"
    fi
    # xctestrun uses __TESTROOT__ for app/test paths. Refuse non-relocatable app paths.
    python3 "$root/scripts/validate-companion-products.py" "$target/Products"
  done
  # The macOS companion, for `--platform macos`. Unlike the iOS products it stays ad hoc signed:
  # a Mac runner must carry a signature to launch, and the signature is what grants its App Sandbox
  # the incoming-connection entitlement the gRPC server needs.
  xcodebuild build-for-testing \
    -project "$root/CompanionApps/iOS/AmooCompanion.xcodeproj" \
    -scheme AmooCompanionMac -destination 'generic/platform=macOS' \
    -derivedDataPath "$root/.build-companion-release/macosx" \
    ONLY_ACTIVE_ARCH=NO "ARCHS=arm64 x86_64"
  target="$root/CompanionApps/iOS/prebuilt/macosx"
  mkdir -p "$target"
  rm -rf "$target/Products"
  cp -R "$root/.build-companion-release/macosx/Build/Products" "$target/Products"
  python3 "$root/scripts/validate-companion-products.py" "$target/Products"
fi
make -C "$root" companion-android-build
mkdir -p "$root/CompanionApps/Android/prebuilt"
cp "$root/CompanionApps/Android/app/build/outputs/apk/debug/app-debug.apk" "$root/CompanionApps/Android/prebuilt/"
cp "$root/CompanionApps/Android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk" "$root/CompanionApps/Android/prebuilt/"
