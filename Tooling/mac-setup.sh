#!/usr/bin/env bash
#
# Turn a freshly rented Apple silicon Mac into a working iOS build box.
#
# Idempotent — safe to re-run on a half-configured machine, which is the normal case when a
# previous session was interrupted. Every step checks before acting.
#
# Xcode is installed with `xcodes` rather than the App Store, because the App Store route needs a
# GUI and this box is only ever reached over SSH. `xcodes` needs an Apple ID; supply it through
# the environment rather than typing it, so the run stays unattended.
#
# Usage:  XCODES_USERNAME=… XCODES_PASSWORD=… ./Tooling/mac-setup.sh
#
set -euo pipefail

XCODE_VERSION="${XCODE_VERSION:-26.0}"
SIMULATOR_RUNTIME="${SIMULATOR_RUNTIME:-iOS 26.0}"

log() { printf '\n=== %s\n' "$*"; }

log "Disk before"
df -h / | tail -1

# ---------------------------------------------------------------------------
# Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv)"

# ---------------------------------------------------------------------------
# Xcode
# ---------------------------------------------------------------------------
if ! xcodebuild -version >/dev/null 2>&1; then
  log "Installing Xcode ${XCODE_VERSION} (this is the slow step — tens of GB)"
  brew install xcodesorg/made/xcodes aria2
  xcodes install "${XCODE_VERSION}" --select
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
else
  log "Xcode already present: $(xcodebuild -version | head -1)"
fi

# Only the runtime actually targeted — each one is ~10 GB and the disk is 256 GB.
if ! xcrun simctl list runtimes | grep -q "${SIMULATOR_RUNTIME}"; then
  log "Downloading simulator runtime ${SIMULATOR_RUNTIME}"
  xcodebuild -downloadPlatform iOS || true
fi

# ---------------------------------------------------------------------------
# Ruby toolchain for fastlane
# ---------------------------------------------------------------------------
# Pinned through the Gemfile so this box and CI resolve identical versions. Divergence between
# "works on the rented Mac" and "works in CI" is the standard way this rots.
if ! command -v bundle >/dev/null 2>&1; then
  log "Installing bundler"
  gem install bundler --no-document
fi

if [ -f "$(dirname "$0")/../Gemfile" ]; then
  log "Installing gems"
  (cd "$(dirname "$0")/.." && bundle config set --local path vendor/bundle && bundle install)
fi

# ---------------------------------------------------------------------------
# Verification — the whole point of the script
# ---------------------------------------------------------------------------
# The box is not "set up" because things installed. It is set up when the full headless loop
# works: build, boot, install, launch, SCREENSHOT, and read logs. The screenshot is the step that
# stops an agent being blind, so it is the one that must be proven.
log "Verifying toolchain"
xcodebuild -version
xcrun simctl list runtimes | grep -i ios || true
echo "available devices:"
xcrun simctl list devices available | head -20

log "Disk after"
df -h / | tail -1

cat <<'EOF'

Toolchain verified. The remaining proof needs a built app:

  xcodebuild -scheme PAI -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
  xcrun simctl boot "iPhone 17 Pro"
  xcrun simctl install booted <path>.app
  xcrun simctl launch booted com.frederikberg.pai
  xcrun simctl io booted screenshot /tmp/shot.png
  xcrun simctl spawn booted log stream --predicate 'subsystem == "com.frederikberg.pai"'

Remember to destroy the instance when the burst is over — a forgotten M4-S is EUR 149/month.
EOF
