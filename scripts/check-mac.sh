#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")/.."
python3 -m unittest discover -s tests -v
if [[ -z "${POCKET_SIMULATOR_ID:-}" ]]; then
    POCKET_SIMULATOR_ID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
catalog=json.load(sys.stdin)
phones=[d for runtime,ds in catalog["devices"].items() if "iOS" in runtime for d in ds if "iPhone" in d["name"]]
if not phones:
    sys.exit("Install an iOS simulator runtime in Xcode first.")
print(phones[0]["udid"])
')
fi
xcodebuild -project ios/CodexPocket.xcodeproj -scheme CodexPocket \
  -destination "platform=iOS Simulator,id=$POCKET_SIMULATOR_ID" \
  -derivedDataPath /tmp/CodexPocketBuild \
  -resultBundlePath "/tmp/CodexPocket-$(date +%Y%m%d%H%M%S).xcresult" \
  CODE_SIGNING_ALLOWED=NO test
