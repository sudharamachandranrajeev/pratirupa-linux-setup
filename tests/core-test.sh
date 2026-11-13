#!/usr/bin/env bash
# Tests for core/pratirupa.sh and the file-only modules, in a throwaway HOME.
# Needs no root and touches nothing outside a temporary folder.
#
#   tests/core-test.sh

# Variables below are read inside the check strings (eval), which shellcheck cannot see.
# shellcheck disable=SC2034,SC2209
set -uo pipefail
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HOME=$tmp/home XDG_STATE_HOME=$tmp/home/.local/state XDG_CACHE_HOME=$tmp/home/.cache XDG_DATA_HOME=$tmp/home/.local/share
mkdir -p "$HOME"
unset HYPRLAND_INSTANCE_SIGNATURE

pass=0 failn=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# shellcheck source=../core/pratirupa.sh
. "$repo/core/pratirupa.sh"
PR_MODULE=test

echo "core: pr_put"
echo one >"$tmp/a"
pr_put "$tmp/a" "$HOME/x/a.txt" >/dev/null
check "new file written" '[[ $(cat "$HOME/x/a.txt") == one ]]'
check "ledger records it with no backup" 'grep -q "^test	file	$HOME/x/a.txt	-	" "$PR_LEDGER"'
before=$(stat -c %Y "$PR_LEDGER")
sleep 1
pr_put "$tmp/a" "$HOME/x/a.txt" >/dev/null
check "unchanged re-run does not touch the ledger" '[[ $(stat -c %Y "$PR_LEDGER") == "$before" ]]'

echo original >"$HOME/x/b.txt"
echo two >"$tmp/b"
pr_put "$tmp/b" "$HOME/x/b.txt" >/dev/null
check "existing file is backed up" '[[ $(cat "$PR_STATE/backup/test$HOME/x/b.txt") == original ]]'
check "and replaced" '[[ $(cat "$HOME/x/b.txt") == two ]]'

echo "my edit" >"$HOME/x/b.txt"
pr_put "$tmp/b" "$HOME/x/b.txt" >/dev/null 2>&1
check "edited-after-install copy is kept" 'grep -qs "my edit" "$PR_STATE"/backup/test"$HOME"/x/b.txt.edited-*'
check "first backup is still the original" '[[ $(cat "$PR_STATE/backup/test$HOME/x/b.txt") == original ]]'

echo "core: pr_block"
printf 'line1\nline2\n' >"$HOME/conf"
pr_block "$HOME/conf" demo '#' <<<'hello' >/dev/null
check "block added" 'grep -q "^hello$" "$HOME/conf" && grep -q "pratirupa:demo" "$HOME/conf"'
sum1=$(sha256sum "$HOME/conf")
pr_block "$HOME/conf" demo '#' <<<'hello' >/dev/null
check "block re-run is a no-op" '[[ $(sha256sum "$HOME/conf") == "$sum1" ]]'
pr_block "$HOME/conf" demo '#' <<<'bye' >/dev/null
check "block replaced, not duplicated" '[[ $(grep -c "pratirupa:demo" "$HOME/conf") == 2 ]] && grep -q "^bye$" "$HOME/conf" && ! grep -q "^hello$" "$HOME/conf"'
pr_block_remove "$HOME/conf" demo
check "block removed leaves the original" '[[ $(cat "$HOME/conf") == $(printf "line1\nline2") ]]'

printf '{\n  "a": 1\n}\n' >"$HOME/menu.jsonc"
PR_BLOCK_AFTER='^[[:space:]]*\{[[:space:]]*$' pr_block "$HOME/menu.jsonc" m // <<<'  "b": 2,' >/dev/null
check "block goes after the opening brace" '[[ $(sed -n 3p "$HOME/menu.jsonc") == "  \"b\": 2," && $(tail -1 "$HOME/menu.jsonc") == "}" ]]'
check "entry before it keeps no comma (JSON stays valid)" 'grep -v "^//" "$HOME/menu.jsonc" | jq -e .b >/dev/null 2>&1 || ! command -v jq >/dev/null'

printf 'keep1\n# >>> pratirupa:dmg (managed by pratirupa; edits inside are replaced)\nold\nuser1\nuser2\n' >"$HOME/damaged"
cp "$HOME/damaged" "$tmp/damaged.orig"
pr_block "$HOME/damaged" dmg '#' <<<'new' >/dev/null 2>&1
check "damaged markers: file left untouched" 'cmp -s "$HOME/damaged" "$tmp/damaged.orig"'
pr_block_remove "$HOME/damaged" dmg >/dev/null 2>&1
check "damaged markers: remove leaves it too" 'cmp -s "$HOME/damaged" "$tmp/damaged.orig"'
printf 'x\n' >"$HOME/prefix"
pr_block "$HOME/prefix" own-scripts '#' <<<'a' >/dev/null
pr_block "$HOME/prefix" own '#' <<<'b' >/dev/null
check "block id is matched exactly, not as a prefix" 'grep -q "^a$" "$HOME/prefix" && grep -q "^b$" "$HOME/prefix"'

echo "core: undo"
(
  PR_MODULE=undo
  echo same >"$tmp/same"; cp "$tmp/same" "$HOME/already"
  pr_put "$tmp/same" "$HOME/already" >/dev/null
  echo fresh >"$tmp/fresh"
  pr_put "$tmp/fresh" "$HOME/fresh" >/dev/null
  echo "user edit" >>"$HOME/fresh"
  pr_undo_ledger >/dev/null 2>&1
)
check "undo keeps a file that was already there" '[[ $(cat "$HOME/already") == same ]]'
check "undo removes a file it created" '[[ ! -e $HOME/fresh ]]'
check "undo saves the user-edited copy first" 'grep -qs "user edit" "$PR_STATE"/backup/undo"$HOME"/fresh.edited-*'
check "ledger never has an empty field" '! grep -qP "\t\t|\t$" "$PR_LEDGER"'

echo "core: packages map"
PR_FAMILY=debian
check "debian maps brave to Flathub" '[[ $(pr_pkg_cell brave) == flatpak:com.brave.Browser ]]'
PR_FAMILY=fedora
check "fedora maps github-cli to gh" '[[ $(pr_pkg_cell github-cli) == gh ]]'
PR_FAMILY=arch
check "arch maps vscode to the AUR" '[[ $(pr_pkg_cell vscode) == aur:visual-studio-code-bin ]]'
check "unknown name is empty" '[[ -z $(pr_pkg_cell no-such-thing) ]]'
cols=$(awk '$0 !~ /^[[:space:]]*#/ && NF > 0 && NF != 5 { print FILENAME ":" NR }' "$repo/core/packages.map")
check "every map row has 5 columns${cols:+ ($cols)}" '[[ -z $cols ]]'

echo "core: detection"
printf 'ID=ubuntu\nID_LIKE=debian\n' >"$tmp/os"
PR_OS_RELEASE=$tmp/os PR_FORCE_OMARCHY=0 pr_detect
check "ubuntu is the debian family" '[[ $PR_FAMILY == debian && $PR_OMARCHY == 0 ]]'
printf 'ID=fedora\n' >"$tmp/os"
PR_OS_RELEASE=$tmp/os PR_FORCE_OMARCHY=0 pr_detect
check "fedora family" '[[ $PR_FAMILY == fedora ]]'
check "omarchy tier refused on fedora" '! pr_tier_ok omarchy >/dev/null'
printf 'ID=opensuse-tumbleweed\nID_LIKE="opensuse suse"\n' >"$tmp/os"
PR_OS_RELEASE=$tmp/os PR_FORCE_OMARCHY=0 pr_detect
check "openSUSE family" '[[ $PR_FAMILY == suse ]]'

echo "module: desktop-hyprland (fake Omarchy HOME)"
omarchy_cfg=${OMARCHY_PATH:-/usr/share/omarchy}/config
if [[ -d $omarchy_cfg/hypr ]]; then
  mkdir -p "$HOME/.config"
  cp -r "$omarchy_cfg/hypr" "$omarchy_cfg/kitty" "$HOME/.config/"
  orig=$(sha256sum "$HOME/.config/hypr/hyprland.lua" | cut -d' ' -f1)
  PR_FORCE_OMARCHY=1 bash "$repo/setup.sh" --yes install desktop-hyprland >"$tmp/out" 2>&1
  check "install succeeds" 'grep -q "==> Done" "$tmp/out" && ! grep -q Failed "$tmp/out"'
  check "pratirupa.lua in place" '[[ -f $HOME/.config/hypr/pratirupa.lua ]]'
  check "hyprland.lua requires it once" '[[ $(grep -c "require(\"hypr.pratirupa\")" "$HOME/.config/hypr/hyprland.lua") == 1 ]]'
  if command -v luac >/dev/null; then
    check "pratirupa.lua parses" 'luac -p "$HOME/.config/hypr/pratirupa.lua"'
  fi
  PR_FORCE_OMARCHY=1 bash "$repo/setup.sh" --yes install desktop-hyprland >/dev/null 2>&1
  check "second run keeps one require" '[[ $(grep -c "require(\"hypr.pratirupa\")" "$HOME/.config/hypr/hyprland.lua") == 1 ]]'
  bash "$repo/setup.sh" status desktop-hyprland >"$tmp/status" 2>&1
  check "status reports ok" '! grep -qE "changed|missing" "$tmp/status" && grep -q ok "$tmp/status"'
  echo "-- edited" >>"$HOME/.config/hypr/pratirupa.lua"
  bash "$repo/setup.sh" status desktop-hyprland >"$tmp/status" 2>&1
  check "status reports an edit as changed" 'grep -q "changed.*pratirupa.lua" "$tmp/status"'
  PR_FORCE_OMARCHY=1 bash "$repo/setup.sh" --yes uninstall desktop-hyprland >/dev/null 2>&1
  check "uninstall removes pratirupa.lua" '[[ ! -e $HOME/.config/hypr/pratirupa.lua ]]'
  check "uninstall restores hyprland.lua exactly" '[[ $(sha256sum "$HOME/.config/hypr/hyprland.lua" | cut -d" " -f1) == "$orig" ]]'
else
  echo "  skip (no Omarchy config on this machine)"
fi

echo "module: desktop-portal file content"
if [[ -f /usr/share/xdg-desktop-portal/hyprland-portals.conf ]] || true; then
  out=$(
    PR_MODULE=desktop-portal
    MOD_DIR=$repo/modules/desktop-portal
    pr_pkg() { :; }
    # shellcheck disable=SC1091
    . "$repo/modules/desktop-portal/module.sh"
    mod_apply >/dev/null 2>&1
    cat "$HOME/.config/xdg-desktop-portal/hyprland-portals.conf"
  )
  check "Secret backend set under [preferred]" 'grep -A3 "^\[preferred\]" <<<"$out" | grep -q "org.freedesktop.impl.portal.Secret=gnome-keyring"'
  check "only one Secret line" '[[ $(grep -c "portal.Secret" <<<"$out") == 1 ]]'
fi

echo "setup.sh"
check "help prints" 'bash "$repo/setup.sh" --help | grep -q "uninstall MODULE"'
check "unknown module refused" '! bash "$repo/setup.sh" --yes install no-such-module >/dev/null 2>&1'
check "root refused" '[[ $EUID -ne 0 ]]'

echo
echo "$pass passed, $failn failed"
((failn == 0))
