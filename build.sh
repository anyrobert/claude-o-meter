#!/usr/bin/env bash
# Builds both Claude-O-Meter apps from Sources/. No Xcode project needed.
#   ClaudeOMeter.app       — menu bar variant
#   ClaudeOMeterFloat.app  — floating draggable button variant
set -euo pipefail
cd "$(dirname "$0")"

ARCH="$(uname -m)"

build_app() {
  local bin="$1" plist="$2"
  shift 2
  echo "Compiling ${bin} (${ARCH})…"
  swiftc -O -parse-as-library -target "${ARCH}-apple-macos13.0" "$@" -o "$bin"
  local app="${bin}.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$plist" "$app/Contents/Info.plist"
  mv "$bin" "$app/Contents/MacOS/$bin"
  # Ad-hoc signature so the Keychain "Always Allow" choice sticks between
  # launches. (Rebuilding produces a new signature → re-prompted once per rebuild.)
  codesign --force --sign - "$app" 2>/dev/null || echo "warning: ad-hoc codesign failed (app still runs)"
  echo "Built $app"
}

build_app ClaudeOMeter Info.plist Sources/Core.swift Sources/MenuBarApp.swift
build_app ClaudeOMeterFloat Info-Float.plist Sources/Core.swift Sources/FloatApp.swift

echo
echo "Run:   open ClaudeOMeter.app        # menu bar"
echo "       open ClaudeOMeterFloat.app   # floating button"
echo "Check: ClaudeOMeter.app/Contents/MacOS/ClaudeOMeter --check"
