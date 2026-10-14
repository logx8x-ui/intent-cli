#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-channel-spec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/main.swift" <<'SWIFT'
print(IntentBuildChannel.current.rawValue)
print(IntentBuildPolicy.current.includesWebsiteAdder ? "website-adder:on" : "website-adder:off")
print(IntentBuildPolicy.current.includesTaskWorkspace ? "tasks:on" : "tasks:off")
SWIFT
swiftc "$ROOT/Sources/IntentCore/IntentBuildPolicy.swift" "$WORK/main.swift" -o "$WORK/launch"
swiftc -D INTENT_DEVELOPMENT "$ROOT/Sources/IntentCore/IntentBuildPolicy.swift" "$WORK/main.swift" -o "$WORK/development"
[[ "$("$WORK/launch")" == $'launch\nwebsite-adder:off\ntasks:off' ]]
[[ "$("$WORK/development")" == $'development\nwebsite-adder:on\ntasks:on' ]]
echo "Both compiled Intent channels passed; launch excludes the website adder and task workspace."
