#!/usr/bin/env bash
# Launch the built macOS app N times and count crashes (a crashed launch leaves a new .ips report or no process).
# Usage: script/launch_stability_test.sh [runs=10] [app path] [support dir]
set -euo pipefail
RUNS="${1:-10}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${2:-}"
SUPPORT="${3:-$(mktemp -d)}"
if [[ -z "$APP" ]]; then
  APP="$(xcodebuild -project "$ROOT/SignalHive.xcodeproj" -scheme SignalHive -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/TARGET_BUILD_DIR = / { dir=$2 } /WRAPPER_NAME = / { wrapper=$2 } END { print dir "/" wrapper }')"
fi
[[ -d "$APP" ]] || { echo "app not found: $APP" >&2; exit 2; }
REPORTS=~/Library/Logs/DiagnosticReports
crashes=0
for i in $(seq 1 "$RUNS"); do
  pkill -x SignalHive 2>/dev/null || true; sleep 1
  before=$(ls "$REPORTS"/SignalHive-*.ips 2>/dev/null | wc -l)
  open -n "$APP" --args -supportDirectory "$SUPPORT"
  sleep 9
  after=$(ls "$REPORTS"/SignalHive-*.ips 2>/dev/null | wc -l)
  if ! pgrep -x SignalHive >/dev/null || [[ "$after" -gt "$before" ]]; then crashes=$((crashes+1)); echo "run $i: CRASH"; else echo "run $i: ok"; fi
done
pkill -x SignalHive 2>/dev/null || true
echo "crashes: $crashes / $RUNS"
[[ "$crashes" -eq 0 ]]
