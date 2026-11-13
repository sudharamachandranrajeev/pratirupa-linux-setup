#!/usr/bin/env bash
# Check the repo for secrets and personal details before a commit or push.
#
#   tools/leak-scan.sh                 scan tracked and staged files
#   tools/leak-scan.sh --history       also scan every commit (gitleaks)
#
# Personal words (names, user names, host names, addresses) are read from a
# deny-list kept OUTSIDE the repo, one regex per line:
#   ${PRATIRUPA_DENYLIST:-~/.config/pratirupa/deny-list.txt}
# Generic patterns (private IPs, MAC addresses, home paths, keys) are built in.

set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here" || exit 1
deny=${PRATIRUPA_DENYLIST:-$HOME/.config/pratirupa/deny-list.txt}
fail=0

mapfile -t files < <(git ls-files --cached --others --exclude-standard)

echo "Scanning ${#files[@]} files"

# 1. Generic patterns.
generic=(
  '/home/[a-z_][a-z0-9_-]*/'                                  # home paths
  '\b(10|127)\.[0-9]+\.[0-9]+\.[0-9]+\b'                      # private / loopback IPv4 with host
  '\b192\.168\.[0-9]+\.[0-9]+\b'
  '\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+\b'
  '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+\b'  # Tailscale CGNAT
  '\b[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}\b'                    # MAC addresses
  '\.ts\.net\b'                                               # tailnet names
  'BEGIN [A-Z ]*PRIVATE KEY'
  '\b(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}'
  '\bsk-[A-Za-z0-9-]{20,}'
  '[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}-[A-Z0-9]{7}'           # Syncthing device IDs
)
# Lines allowed to match (whole private ranges, documentation addresses and
# this file's own patterns).
allow='10\.0\.0\.0/8|172\.16\.0\.0/12|192\.168\.0\.0/16|127\.0\.0\.1|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|tools/leak-scan\.sh'

for pat in "${generic[@]}"; do
  hits=$(grep -nHIE "$pat" "${files[@]}" 2>/dev/null | grep -vE "$allow" | grep -v '^tools/leak-scan.sh:')
  if [[ -n $hits ]]; then
    echo "Pattern /$pat/:"
    sed 's/^/  /' <<<"$hits"
    fail=1
  fi
done

# 2. Personal deny-list.
if [[ -f $deny ]]; then
  while IFS= read -r pat; do
    [[ -z $pat || $pat == \#* ]] && continue
    hits=$(grep -nHIiE "$pat" "${files[@]}" 2>/dev/null)
    if [[ -n $hits ]]; then
      echo "Deny-list match (pattern not shown):"
      cut -d: -f1,2 <<<"$hits" | sed 's/^/  /'
      fail=1
    fi
  done <"$deny"
else
  echo "Warning: no deny-list at $deny; personal-word check skipped." >&2
  fail=1
fi

# 3. gitleaks: installed, or run through mise when only mise is there.
gitleaks=()
if gitleaks version >/dev/null 2>&1; then gitleaks=(gitleaks)
elif command -v mise >/dev/null && mise exec gitleaks@latest -- gitleaks version >/dev/null 2>&1; then
  gitleaks=(mise exec gitleaks@latest -- gitleaks)
fi
if ((${#gitleaks[@]})); then
  if [[ ${1:-} == --history ]]; then
    "${gitleaks[@]}" git --no-banner --redact . || fail=1
  else
    "${gitleaks[@]}" dir --no-banner --redact . || fail=1
  fi
else
  echo "Warning: gitleaks not installed; secret scan skipped." >&2
  fail=1
fi

if ((fail)); then echo "Leak scan: FAILED"; exit 1; fi
echo "Leak scan: clean"
