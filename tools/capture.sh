#!/usr/bin/env bash
# Compare this Omarchy machine with Omarchy's defaults and with what the
# Pratirupa modules already cover, so the modules can be kept current.
#
#   ./setup.sh capture            print the report
#   ./setup.sh capture --save F   also save it to F (keep it outside the repo:
#                                 it names files and units on this machine)
#
# It only reads. It never copies anything into the repo: personal files
# (keys, logins, browser profiles, host names) must be added to a module by
# hand, scrubbed, and passed through tools/leak-scan.sh first.

set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY=${OMARCHY_PATH:-/usr/share/omarchy}
save=''
[[ ${1:-} == --save ]] && save=${2:?--save needs a file}

[[ -d $OMARCHY/install ]] || { echo "capture needs Omarchy (no $OMARCHY/install)." >&2; exit 1; }

report() {
  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  # Packages Omarchy installs itself.
  cat "$OMARCHY"/install/omarchy-base.packages "$OMARCHY"/install/omarchy-other.packages \
    "$OMARCHY/install/omarchy-$(uname -m)-only.packages" 2>/dev/null |
    sed 's/#.*//' | tr -s ' \t' '\n' | grep -v '^$' | sort -u >"$tmp/omarchy"

  # Packages the map covers (arch column, every alternative, prefixes dropped).
  awk '$0 !~ /^[[:space:]]*#/ && NF >= 2 { print $2 }' "$here/core/packages.map" |
    tr '|,' '\n\n' | sed 's/^aur://; s/^flatpak:.*//' | grep -v '^-\?$' | sort -u >"$tmp/covered"

  # Packages that are hardware, boot or Omarchy plumbing: never replicated.
  printf '%s\n' linux linux-headers linux-lts linux-zen intel-ucode amd-ucode mkinitcpio efibootmgr \
    sudo omarchy omarchy-keyring omarchy-settings lib32-vulkan-intel lib32-vulkan-radeon libxml2-legacy \
    usbmuxd rust voxtype-bin | sort -u >"$tmp/ignored"
  # rust: dev-toolchain installs Rust through rustup. voxtype-bin: Omarchy's
  # own dictation installer (menu > Install > Dictation) sets it up.

  pacman -Qqe | sort -u >"$tmp/explicit"
  comm -23 "$tmp/explicit" "$tmp/omarchy" | comm -23 - "$tmp/ignored" >"$tmp/extra"

  echo "# Pratirupa capture — $(date +%F)"
  echo
  echo "## Packages added on top of Omarchy"
  echo
  echo "Not covered by core/packages.map yet (add a row, or ignore):"
  comm -23 "$tmp/extra" "$tmp/covered" | sed 's/^/  - /'
  echo
  echo "Already covered: $(comm -12 "$tmp/extra" "$tmp/covered" | wc -l) packages."
  echo

  echo "## Omarchy config files changed from the defaults"
  echo
  (cd "$OMARCHY/config" && find . -type f | sed 's|^\./||') | while read -r f; do
    [[ -f $HOME/.config/$f ]] && ! cmp -s "$OMARCHY/config/$f" "$HOME/.config/$f" && echo "  - ~/.config/$f"
  done
  echo

  echo "## Omarchy themes, plugins and hooks on this machine"
  echo
  local d
  for d in "$HOME"/.config/omarchy/themes/*/; do [[ -d $d ]] && echo "  - theme $(basename "$d")"; done
  for d in "$HOME"/.config/omarchy/plugins/*/; do [[ -d $d ]] && echo "  - plugin $(basename "$d")"; done
  find "$HOME/.config/omarchy/hooks" -type f ! -name '*.sample' 2>/dev/null | sed "s|^$HOME|~|; s/^/  - hook /"
  echo

  echo "## User services (~/.config/systemd/user)"
  echo
  find "$HOME/.config/systemd/user" -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.path' \) 2>/dev/null |
    sed "s|^$HOME|~|; s/^/  - /"
  echo

  echo "## System units and drop-ins not owned by a package (/etc/systemd/system)"
  echo
  local f
  find /etc/systemd/system -maxdepth 2 \( -type f -name '*.service' -o -type f -name '*.timer' -o -type f -name '*.path' -o -type f -name '*.conf' \) 2>/dev/null |
    while read -r f; do pacman -Qqo "$f" >/dev/null 2>&1 || echo "  - $f"; done
  echo

  echo "## Programs in ~/.local/bin"
  echo
  find "$HOME/.local/bin" -maxdepth 1 \( -type f -o -type l \) -printf '  - %f\n' 2>/dev/null | sort
  echo
  echo "Next: move anything worth replicating into a module, scrub it, then run tools/leak-scan.sh."
}

if [[ -n $save ]]; then
  case $(realpath -m "$save") in "$here"/*) echo "Save the report outside the repo." >&2; exit 1 ;; esac
  report | tee "$save"
else
  report
fi
