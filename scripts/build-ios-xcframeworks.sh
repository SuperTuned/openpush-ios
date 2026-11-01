#!/bin/bash
# Builds static, library-evolution XCFrameworks from this SwiftPM package for wrapper SDKs that
# vendor binaries (the Unity package). SwiftPM archives of `automatic` products yield only .o files,
# so each framework is assembled by hand: libtool the object into a static archive, copy the
# textual interfaces (no binary .swiftmodule, so every consumer proves module stability), add the
# privacy manifest and an Info.plist, then -create-xcframework.
#
# -alias-module-names-in-module-interface is mandatory: the OpenPush module declares a type named
# OpenPush, and without the alias the emitted interface fails verification with
# "'OpenPush' is not a member type of enum 'OpenPush.OpenPush'".
#
# Build with the OLDEST Xcode the consumers support: a textual interface needs a compiler at least
# as new as the one that wrote it. The Xcode and Swift versions are recorded in the version stamp.
#
# Output is reproducible: the same commit and toolchain give byte-identical files, so re-vendoring
# an unchanged SDK produces no diff, whatever the checkout is called or where it lives. The build
# compiles a `git archive HEAD` copy extracted to a fixed folder name (SwiftPM derives the
# -package-name written into the .package.swiftinterface from that folder name), so uncommitted
# edits are never built. The build paths are remapped out of debug info (-file-prefix-map), the
# debug-map stabs that name intermediate objects are stripped (strip -S), libtool
# runs in deterministic mode (-D: no timestamps, uids or gids), each xcframework Info.plist lists
# its slices in sorted order, and the *.abi.json files, which embed absolute build paths and are not
# needed by consumers, are left out.
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd -P)"
OUT="$PKG/build/xcframeworks"
while [ $# -gt 0 ]; do
  case "$1" in
    --output) [ $# -ge 2 ] || { echo "usage: $0 [--output <dir>]" >&2; exit 2; }; OUT="$2"; shift 2 ;;
    *) echo "usage: $0 [--output <dir>]" >&2; exit 2 ;;
  esac
done
WORK="$PKG/build/.xcf-work"
SRC="$WORK/src/openpush-ios"
# The output is wiped before the build, so it must not overlap the work dir in either direction.
OUT="$(/usr/bin/python3 - "$OUT" "$WORK" <<'PY'
import os, sys
out, work = os.path.realpath(sys.argv[1]), sys.argv[2]
if os.path.commonpath([out, work]) in (out, work):
    sys.exit(f"refusing --output {out}: it is inside, equal to, or a parent of the work dir {work}")
print(out)
PY
)"
rm -rf "$WORK"; mkdir -p "$SRC"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
git -C "$PKG" archive --format=tar HEAD | tar -x -C "$SRC"

VERSION="$(sed -n 's/.*static let current = "\([0-9][0-9.]*\)".*/\1/p' "$SRC/Sources/OpenPushCore/OpenPushSDKVersion.swift")"
[ -n "$VERSION" ] || { echo "could not read OpenPushSDKVersion.current" >&2; exit 1; }

FLAGS=(SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
       "OTHER_SWIFT_FLAGS=\$(inherited) -Xfrontend -alias-module-names-in-module-interface -file-prefix-map \"$SRC=/openpush-ios\" -file-prefix-map \"$WORK=/xcf-work\"")
for scheme in OpenPush OpenPushNSE; do
  for plat in "iOS:iphoneos" "iOS Simulator:iphonesimulator"; do
    dest="${plat%%:*}"; sdk="${plat##*:}"
    echo "→ archive $scheme ($sdk)"
    ( cd "$SRC" && xcodebuild archive -scheme "$scheme" -destination "generic/platform=$dest" \
        -archivePath "$WORK/$scheme-$sdk" -derivedDataPath "$WORK/dd-$scheme-$sdk" "${FLAGS[@]}" \
        > "$WORK/$scheme-$sdk.log" 2>&1 ) || { echo "FAILED $scheme $sdk"; tail -30 "$WORK/$scheme-$sdk.log"; exit 1; }
  done
done

for mod in OpenPushCore OpenPushLiveActivities OpenPush OpenPushNSE; do
  scheme=OpenPush; [ "$mod" = OpenPushNSE ] && scheme=OpenPushNSE
  args=()
  for sdk in iphoneos iphonesimulator; do
    fw="$WORK/fw/$sdk/$mod.framework"; mkdir -p "$fw/Modules/$mod.swiftmodule"
    obj="$(find "$WORK/$scheme-$sdk.xcarchive/Products" -name "$mod.o" | head -1)"
    [ -n "$obj" ] || { echo "no $mod.o in $scheme-$sdk archive" >&2; exit 1; }
    # strip -S drops the debug-map stabs, which name absolute build paths of intermediate objects
    # that consumers never have; the symbol table and every section stay intact.
    stripped="$WORK/obj/$sdk/$mod.o"; mkdir -p "${stripped%/*}"
    xcrun strip -S -o "$stripped" "$obj"
    libtool -static -D -o "$fw/$mod" "$stripped"
    mod_dir="$(find "$WORK/dd-$scheme-$sdk" -path "*BuildProductsPath/Release-$sdk/$mod.swiftmodule" -type d | head -1)"
    [ -n "$mod_dir" ] || { echo "no $mod.swiftmodule for $sdk" >&2; exit 1; }
    rsync -a --exclude '*.swiftmodule' --exclude '*.abi.json' --exclude 'Project' "$mod_dir/" "$fw/Modules/$mod.swiftmodule/"
    cp "$SRC/Sources/$mod/Resources/PrivacyInfo.xcprivacy" "$fw/"
    cat > "$fw/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$mod</string>
<key>CFBundleIdentifier</key><string>ai.openpush.$mod</string>
<key>CFBundleName</key><string>$mod</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>MinimumOSVersion</key><string>16.0</string>
</dict></plist>
PL
    args+=(-framework "$fw")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$OUT/$mod.xcframework" >/dev/null
  # -create-xcframework lists the slices in no fixed order; sort them so Info.plist is stable.
  /usr/bin/python3 - "$OUT/$mod.xcframework/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    info = plistlib.load(f)
info["AvailableLibraries"].sort(key=lambda lib: lib["LibraryIdentifier"])
with open(path, "wb") as f:
    plistlib.dump(info, f, fmt=plistlib.FMT_XML, sort_keys=True)
PY
done

( cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name openpush-ios.version.txt | LC_ALL=C sort \
    | sed 's|^\./||' | xargs shasum -a 256 > SHA256SUMS )
cat > "$OUT/openpush-ios.version.txt" <<EOF
version=$VERSION
source_repository=openpush-ios
source_commit=$(git -C "$PKG" rev-parse HEAD)
source_tag=$(git -C "$PKG" describe --tags --exact-match 2>/dev/null || echo none)
xcode=$(xcodebuild -version | tr '\n' ' ' | sed 's/ *$//')
swift=$(xcrun swift --version 2>/dev/null | head -1)
linkage=static
slices=ios-arm64,ios-arm64_x86_64-simulator
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
du -sh "$OUT"/*.xcframework
