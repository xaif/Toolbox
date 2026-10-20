#!/bin/zsh
set -uo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet || exit 1
mkdir -p build
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration Debug \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test > build/last-test.log 2>&1
test_result=$?
grep -E '^/.*error:|Test Case.*(passed|failed)|Executed |TEST (SUCCEEDED|FAILED)' build/last-test.log | tail -60
if [ "$test_result" -ne 0 ]; then tail -12 build/last-test.log; fi
exit "$test_result"
