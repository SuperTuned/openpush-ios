#!/bin/sh
# Regenerates every fixture's .xcodeproj from its project.yml. The generated
# projects are committed, so the tests never need XcodeGen; run this only after
# changing a project.yml, then commit both.
set -eu
cd "$(dirname "$0")"
for spec in */project.yml; do
  dir=$(dirname "$spec")
  (cd "$dir" && xcodegen generate --quiet)
done
# A pinned package, as Xcode writes it after resolving.
resolved=CustomExtension/Shop.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved"
cat > "$resolved/Package.resolved" <<'JSON'
{
  "originHash" : "0000000000000000000000000000000000000000000000000000000000000000",
  "pins" : [
    {
      "identity" : "rich-media-ios",
      "kind" : "remoteSourceControl",
      "location" : "https://github.com/example/rich-media-ios",
      "state" : {
        "revision" : "1111111111111111111111111111111111111111",
        "version" : "2.1.4"
      }
    }
  ],
  "version" : 3
}
JSON
