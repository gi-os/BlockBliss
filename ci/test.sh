#!/bin/bash
# Engine tests + a short Monte-Carlo run (every dealt tray must be solvable), then a simulator build.
set -euo pipefail
source ci/app.env
swift test 2>&1 | tail -40
swift run -c release blocksim --games 200 2>&1 | tail -40
DEV=$(bash ci/sim.sh)
echo "Building for simulator $DEV"
xcodebuild build -project "$SCHEME.xcodeproj" -scheme "$SCHEME" -destination "id=$DEV" \
  CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | tail -80
exit ${PIPESTATUS[0]}
