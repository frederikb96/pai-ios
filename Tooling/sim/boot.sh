#!/usr/bin/env bash
# Boot a simulator without waiting for it, then wait for it separately, so the boot can overlap
# the build. Started and waited on across two steps, or one after the other on a Mac.
#
#   boot.sh start        pick a device, boot it, print its udid
#   boot.sh wait <udid>  wait until usable; a hung boot is shut down and retried
set -o pipefail
# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

attempts=3
attempt_seconds=${SIM_BOOT_TIMEOUT:-480}

case "${1:-}" in
  start)
    udid=$(sim_pick_device)
    [ -n "$udid" ] || { echo 'no iPhone simulator available' >&2; exit 1; }
    xcrun simctl boot "$udid" >&2 || true
    echo "$udid"
    ;;
  wait)
    udid=${2:?usage: boot.sh wait <udid>}
    for attempt in $(seq 1 "$attempts"); do
      if sim_wait_booted "$udid" "$attempt_seconds"; then
        echo "booted on attempt $attempt after ${SECONDS}s"
        after_boot "$udid"
        exit 0
      fi
      echo "::warning::simulator not booted after ${attempt_seconds}s (attempt $attempt of $attempts)"
      xcrun simctl shutdown "$udid" || true
      xcrun simctl boot "$udid" || true
    done
    echo "::error::simulator never finished booting"
    exit 1
    ;;
  *)
    echo 'usage: boot.sh start | wait <udid>' >&2
    exit 2
    ;;
esac
