#!/bin/sh
# Applies setup to a copy of each buildable fixture, then builds the result for
# the simulator with signing off. The unit tests prove what apply writes; this
# proves Xcode accepts it. OpenPush is linked from this checkout, so nothing is
# fetched.
#
# What each run covers: share (TwoGroups, ManualSigning, GeneratedInfoPlist),
# inject (GroupWithoutExtension, ManualSigningAppOnly, WidgetAndContent, SynchronizedFolder — an
# Xcode 16 synchronized folder whose app gains its first Info.plist), take_over
# (OneSignalStyleExport), and a created widget under manual signing.
#
# ObjCExtension (setup refuses to edit it) and VendoredFrameworks (its
# frameworks are placeholders) are scanned and applied in the unit tests only.
# CustomExtension is left out: it depends on a made-up package that cannot
# resolve. The vendor export links through CocoaPods, which this script does
# not install, so its Podfile is removed from the copy to link with SwiftPM
# instead, and only the extension is built: its app targets iOS 13, which
# OpenPush does not support.
set -eu

tool=$(cd "$(dirname "$0")/.." && pwd)
sdk=$(cd "$tool/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swift build --package-path "$tool" --product openpush-ios-setup
setup="$tool/.build/debug/openpush-ios-setup"

# build <fixture> <scheme> [apply options...]
build() {
  fixture=$1
  scheme=$2
  shift 2
  cp -R "$tool/Tests/Fixtures/$fixture" "$work/$fixture"
  if [ "${WITHOUT_PODS:-}" = 1 ]; then rm -f "$work/$fixture/Podfile" "$work/$fixture/Podfile.lock"; fi
  "$setup" apply --project "$work/$fixture" --yes --app-id app-1 --sdk-key key-1 \
    --package-path "$sdk" "$@"
  project=$(ls -d "$work/$fixture"/*.xcodeproj)
  xcodebuild build -project "$project" -scheme "$scheme" \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$work/DerivedData-$fixture" \
    CODE_SIGNING_ALLOWED=NO -quiet
  echo "Built applied fixture: $fixture ($scheme)"
}

build TwoGroups Duo
build ManualSigning Bank --widget-mode new --widget-profile "Debug=Bank Widget Dev,Release=Bank Widget Store"
build GeneratedInfoPlist Notes
build WidgetAndContent Gallery
build GroupWithoutExtension Solo --app-group group.com.example.solo
WITHOUT_PODS=1 build OneSignalStyleExport OneSignalNotificationServiceExtension
build SynchronizedFolder Sync
build ManualSigningAppOnly Vault --app-group group.com.example.vault --nse-profile "Vault NSE"
