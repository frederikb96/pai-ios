#!/usr/bin/env bash
# Install the built app on a booted simulator.
#
#   install.sh <udid> <derived-data-path>
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

udid=${1:?usage: install.sh <udid> <derived-data-path>}
app=$(sim_find_app "${2:?usage: install.sh <udid> <derived-data-path>}")
[ -n "$app" ] || { echo 'build produced no .app'; exit 1; }
xcrun simctl install "$udid" "$app"
after_install "$udid"
