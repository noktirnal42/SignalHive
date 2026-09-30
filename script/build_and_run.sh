#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/SignalHive.xcodeproj"
SCHEME="SignalHive"
DESTINATION="platform=macOS"
APP_NAME="SignalHive"
SUPPORT_DIR=""
MOCK_DATA=0
VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mock-data)
      MOCK_DATA=1
      shift
      ;;
    --support-directory)
      SUPPORT_DIR="${2:-}"
      shift 2
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    --help|-h)
      cat <<USAGE
Usage: script/build_and_run.sh [--mock-data] [--support-directory DIR] [--verify]

Builds and launches the macOS SignalHive app.
  --mock-data              Launch with the built-in realistic Alabama dataset.
  --support-directory DIR  Keep app data isolated in DIR.
  --verify                 Confirm the app process is running after launch.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

cd "$ROOT"

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
fi

xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" build

APP_PATH="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DESTINATION" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/TARGET_BUILD_DIR = / { dir=$2 } /WRAPPER_NAME = / { wrapper=$2 } END { if (dir && wrapper) print dir "/" wrapper }')"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Could not locate built app bundle." >&2
  exit 1
fi

/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

ARGS=()
if [[ -n "$SUPPORT_DIR" ]]; then
  mkdir -p "$SUPPORT_DIR"
  ARGS+=("-supportDirectory" "$SUPPORT_DIR")
fi
if [[ "$MOCK_DATA" -eq 1 ]]; then
  ARGS+=("-mockData" "YES")
fi

if [[ "${#ARGS[@]}" -gt 0 ]]; then
  /usr/bin/open "$APP_PATH" --args "${ARGS[@]}"
else
  /usr/bin/open "$APP_PATH"
fi

if [[ "$VERIFY" -eq 1 ]]; then
  for _ in {1..30}; do
    if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      echo "Launched $APP_PATH"
      exit 0
    fi
    sleep 0.5
  done
  echo "$APP_NAME did not stay running." >&2
  exit 1
fi

echo "Launched $APP_PATH"
