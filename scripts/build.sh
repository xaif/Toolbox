#!/bin/zsh
# Usage: scripts/build.sh            -> fast compile check (no signing)
#        scripts/build.sh --sign     -> signed Debug build
#        scripts/build.sh --release  -> signed Release build
set -uo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet || exit 1
CONFIG=Debug
SIGN=(CODE_SIGNING_ALLOWED=NO)
case "${1:-}" in
  --sign) SIGN=() ;;
  --release) SIGN=(); CONFIG=Release ;;
esac
LOG=build/last-build.log
mkdir -p build
xcodebuild -project Toolbox.xcodeproj -scheme Toolbox -configuration "$CONFIG" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' \
  "${SIGN[@]}" build > "$LOG" 2>&1
STATUS=$?
grep -E "(error|warning: unre|fatal):" "$LOG" | grep -v "^ld: warning" | sort -u | head -80
if [ $STATUS -eq 0 ]; then
  echo "BUILD SUCCEEDED: build/DerivedData/Build/Products/$CONFIG/Toolbox.app"
else
  echo "BUILD FAILED (full log: $LOG)"; tail -5 "$LOG"
fi
exit $STATUS
