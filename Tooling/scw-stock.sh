#!/usr/bin/env bash
#
# Report Apple silicon stock across Scaleway's Paris zones.
#
# Stock is the binding constraint on getting a build machine — every macOS type is frequently
# `no_stock`, and the console has been observed showing stale availability, so ask the API.
#
# Credentials come from ~/.claude/.sops.env, which uses the `scw` CLI's own variable names, so
# nothing here needs a wrapper. Values are never printed.
#
# Usage:  ./Tooling/scw-stock.sh            # all types
#         ./Tooling/scw-stock.sh --available # only what can be ordered right now
#
set -euo pipefail

ZONES=(fr-par-1 fr-par-3)
ONLY_AVAILABLE=false
[ "${1:-}" = "--available" ] && ONLY_AVAILABLE=true

eval "$(SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  sops -d "$HOME/.claude/.sops.env" 2>/dev/null | grep -E '^SCW_' | sed 's/^/export /')"

if [ -z "${SCW_SECRET_KEY:-}" ]; then
  echo "SCW_SECRET_KEY not available — is .sops.env readable?" >&2
  exit 1
fi

found=0
for zone in "${ZONES[@]}"; do
  out="$(mktemp)"
  code=$(curl -s -H "X-Auth-Token: $SCW_SECRET_KEY" \
    "https://api.scaleway.com/apple-silicon/v1alpha1/zones/$zone/server-types" \
    -o "$out" -w '%{http_code}')

  if [ "$code" != "200" ]; then
    echo "$zone: HTTP $code" >&2
    rm -f "$out"
    continue
  fi

  # Asahi types run Fedora, not macOS — they cannot build iOS and are filtered out, because
  # they are often the only thing in stock and look like an option when they are not.
  filter='.server_types[] | select(.default_os.label | test("macOS"))'
  $ONLY_AVAILABLE && filter="$filter | select(.stock != \"no_stock\")"

  while IFS=$'\t' read -r name stock cores ram disk os; do
    [ -z "$name" ] && continue
    found=$((found + 1))
    printf '%-10s %-10s %-9s %-6s %-7s %s  [%s]\n' \
      "$name" "$stock" "${cores}C" "${ram}GB" "${disk}GB" "$os" "$zone"
  done < <(jq -r "$filter"' | [.name, .stock, (.cpu.core_count|tostring),
      ((.memory.capacity/1000000000)|floor|tostring),
      ((.disk.capacity/1000000000)|floor|tostring), .default_os.label] | @tsv' "$out")

  rm -f "$out"
done

if [ "$found" -eq 0 ]; then
  echo "No macOS server types match — everything is out of stock."
  exit 2
fi
