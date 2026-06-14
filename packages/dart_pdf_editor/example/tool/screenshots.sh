#!/usr/bin/env bash
#
# Capture native device screenshots of the DartPDF app and the example
# app on iOS, macOS, and Android. Boots each requested device once, then
# drives the self-driving screenshot entry of each target through its
# showcase states, firing the platform's native screenshot tool per
# state. PNGs land at:
#
#   doc/screenshots/<target>/<platform>/NN-name.png
#
# Usage:
#   tool/screenshots.sh [targets...] [platforms...]
#
#   targets    : app | example          (default: both)
#   platforms  : ios | macos | android  (default: all three)
#   (tokens may be given in any order, e.g. `screenshots.sh app macos`)
#
# Env overrides:
#   FLUTTER        flutter binary (default: fvm flutter, else flutter)
#   IOS_DEVICE     simulator name or UDID (default: "iPhone 17 Pro Max")
#   ANDROID_AVD    AVD name             (default: first `emulator -list-avds`)
#   KEEP_BOOTED    1 to leave sims/emulators running afterwards
#
# Requires: Xcode + simulators (ios), Android SDK + an AVD (android), the
# macOS desktop build toolchain (macos). On the first macOS run, grant the
# terminal Automation/Accessibility access when prompted (used to crop the
# capture to the app window).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OUT_ROOT="$REPO_ROOT/doc/screenshots"

# Prefer fvm so the pinned Flutter version matches the repo's .fvmrc.
# DART_CMD runs the host orchestrator; it must come from the same SDK.
if [[ -n "${FLUTTER:-}" ]]; then
  FLUTTER_CMD=($FLUTTER)
  DART_CMD=("${FLUTTER%flutter}dart")        # sibling dart next to flutter
elif command -v fvm >/dev/null 2>&1; then
  FLUTTER_CMD=(fvm flutter)
  DART_CMD=(fvm dart)
else
  FLUTTER_CMD=(flutter)
  DART_CMD=(dart)
fi

IOS_DEVICE="${IOS_DEVICE:-iPhone 17 Pro Max}"

log() { printf '\033[1;34m[screenshots]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[screenshots]\033[0m %s\n' "$*" >&2; }

# ----------------------------------------------------------- targets ----
# Each target: <dir> <run-entry> <macOS process name>.
target_dir() { case "$1" in
  app) echo "$REPO_ROOT/app" ;;
  example) echo "$REPO_ROOT/packages/dart_pdf_editor/example" ;;
esac; }
target_entry() { case "$1" in
  app) echo "tool/screenshots_main.dart" ;;
  example) echo "lib/screenshots_main.dart" ;;
esac; }
target_proc() { case "$1" in
  app) echo "DartPDF" ;;
  example) echo "pdf_viewer_example" ;;
esac; }

# ------------------------------------------------------- arg parsing ----
TARGETS=()
PLATFORMS=()
for tok in "$@"; do
  case "$tok" in
    app|example) TARGETS+=("$tok") ;;
    ios|macos|android) PLATFORMS+=("$tok") ;;
    *) warn "ignoring unknown token '$tok'" ;;
  esac
done
[[ ${#TARGETS[@]} -eq 0 ]] && TARGETS=(app example)
[[ ${#PLATFORMS[@]} -eq 0 ]] && PLATFORMS=(ios macos android)

# Resolve workspace deps once (covers the app's example dev-dependency).
( cd "$REPO_ROOT" && "${FLUTTER_CMD[@]}" pub get >/dev/null )

# capture <target> <flutter-device-id> <SHOT_PLATFORM> <SHOT_DEVICE> <mac-proc>
capture() {
  local target="$1" device_id="$2" shot_platform="$3" shot_device="$4"
  local dir entry proc out
  dir="$(target_dir "$target")"
  entry="$(target_entry "$target")"
  proc="$(target_proc "$target")"
  out="$OUT_ROOT/$target"
  log "[$target] driving $shot_platform on '$device_id' → doc/screenshots/$target/$shot_platform/"
  ( cd "$dir" &&
    FLUTTER="${FLUTTER_CMD[*]}" \
    SHOT_PLATFORM="$shot_platform" SHOT_DEVICE="$shot_device" \
    FLUTTER_DEVICE="$device_id" SHOT_ENTRY="$entry" \
    SHOT_MAC_PROCESS="$proc" SHOT_OUT="$out" \
      "${DART_CMD[@]}" run "$SCRIPT_DIR/capture_screenshots.dart" )
}

# ------------------------------------------------ device boot per OS ----
# Each returns "<flutter-device-id>\t<shot-device>" on stdout, or empty to
# skip. KEEP_BOOTED leaves devices up; otherwise they're shut down at the
# end of the run.
IOS_UDID="" ANDROID_SERIAL="" ANDROID_STARTED=0

boot_ios() {
  command -v xcrun >/dev/null || { warn "xcrun not found; skipping iOS"; return 1; }
  IOS_UDID="$(xcrun simctl list devices available \
    | grep -F "$IOS_DEVICE" | head -1 \
    | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
  [[ -z "$IOS_UDID" ]] && { warn "no available simulator matching '$IOS_DEVICE'; skipping iOS"; return 1; }
  log "booting iOS simulator $IOS_DEVICE ($IOS_UDID)"
  xcrun simctl boot "$IOS_UDID" 2>/dev/null || true
  open -a Simulator
  xcrun simctl bootstatus "$IOS_UDID" -b || true
  return 0
}

ANDROID_ADB=""
boot_android() {
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
  local emu="$sdk/emulator/emulator"
  ANDROID_ADB="$(command -v adb || echo "$sdk/platform-tools/adb")"
  [[ -x "$emu" && -x "$ANDROID_ADB" ]] || { warn "Android SDK/emulator not found; skipping android"; return 1; }
  local avd="${ANDROID_AVD:-}"
  [[ -z "$avd" ]] && avd="$("$emu" -list-avds | head -1 || true)"
  [[ -z "$avd" ]] && { warn "no AVD found; skipping android"; return 1; }
  ANDROID_SERIAL="$("$ANDROID_ADB" devices | awk '/^emulator-/{print $1; exit}')"
  if [[ -z "$ANDROID_SERIAL" ]]; then
    log "booting Android emulator $avd"
    "$emu" -avd "$avd" -no-snapshot-save -no-boot-anim -gpu auto >/tmp/dart_pdf_emulator.log 2>&1 &
    ANDROID_STARTED=1
    "$ANDROID_ADB" wait-for-device
    until [[ "$("$ANDROID_ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; do
      sleep 2
    done
    ANDROID_SERIAL="$("$ANDROID_ADB" devices | awk '/^emulator-/{print $1; exit}')"
  else
    log "reusing running emulator $ANDROID_SERIAL"
  fi
  return 0
}

cleanup() {
  [[ "${KEEP_BOOTED:-0}" == "1" ]] && return
  [[ -n "$IOS_UDID" ]] && xcrun simctl shutdown "$IOS_UDID" 2>/dev/null || true
  [[ "$ANDROID_STARTED" == "1" && -n "$ANDROID_SERIAL" ]] && \
    "$ANDROID_ADB" -s "$ANDROID_SERIAL" emu kill 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------- run loop ----
for platform in "${PLATFORMS[@]}"; do
  case "$platform" in
    macos)
      [[ "$(uname)" == "Darwin" ]] || { warn "not macOS; skipping macos"; continue; }
      for t in "${TARGETS[@]}"; do capture "$t" macos macos ""; done
      ;;
    ios)
      boot_ios || continue
      for t in "${TARGETS[@]}"; do capture "$t" "$IOS_UDID" ios "$IOS_UDID"; done
      ;;
    android)
      boot_android || continue
      for t in "${TARGETS[@]}"; do capture "$t" "$ANDROID_SERIAL" android "$ANDROID_SERIAL"; done
      ;;
  esac
done

log "done. screenshots under $OUT_ROOT/"
