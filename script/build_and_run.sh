#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-run}"
pkill -x "DigUp Personal" >/dev/null 2>&1 || true
./build.sh
APP="$PWD/build.noindex/DigUp Personal.app"
case "$MODE" in
  run) open -n "$APP" ;;
  --debug) lldb -- "$APP/Contents/MacOS/DigUp Personal" ;;
  --logs|--telemetry)
    open -n "$APP"
    /usr/bin/log stream --info --style compact --predicate 'process == "DigUp Personal"'
    ;;
  --verify) open -n "$APP"; sleep 1; pgrep -x "DigUp Personal" >/dev/null ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
