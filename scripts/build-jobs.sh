#!/usr/bin/env bash
# Source before SwiftPM builds. One compiler worker is the laptop-safe default;
# an explicit bounded override remains available on dedicated build machines.
export INTENT_BUILD_JOBS="${INTENT_BUILD_JOBS:-1}"
case "$INTENT_BUILD_JOBS" in
  [1-8]) ;;
  *) printf 'INTENT_BUILD_JOBS must be a whole number from 1 to 8.\n' >&2
     return 64 2>/dev/null || exit 64 ;;
esac
