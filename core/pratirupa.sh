#!/usr/bin/env bash
# Pratirupa core: the shared Linux layer every module uses.
#
# It answers "what machine is this?" (pr_detect), installs packages on any
# supported distro from one generic name (pr_pkg), writes files without ever
# losing what was there (pr_put, pr_block), manages systemd units (pr_unit),
# fetches GitHub releases and repos (pr_release, pr_clone), and records every
# change in a ledger so `status` can report drift and `uninstall` can put the
# machine back.
#
# Source it; do not run it. Modules call only the pr_* functions below.

# shellcheck disable=SC2034  # variables here are read by modules and setup.sh

[[ -n ${PR_CORE_LOADED:-} ]] && return 0
PR_CORE_LOADED=1

PR_ROOT=${PR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
PR_STATE=${PR_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/pratirupa}
PR_CACHE=${PR_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/pratirupa}
PR_LEDGER=$PR_STATE/ledger.tsv
PR_LOG=$PR_STATE/install.log
PR_MAP=$PR_ROOT/core/packages.map
PR_OWNER=${PR_OWNER:-sudharamachandranrajeev}

PR_DRY_RUN=${PR_DRY_RUN:-0}
PR_YES=${PR_YES:-0}
PR_ALLOW_REMOTE=${PR_ALLOW_REMOTE:-0}
PR_MODULE=${PR_MODULE:-core}

PR_NOTES=()   # skipped items and follow-ups, printed in the summary

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
  _c_dim=$'\e[2m' _c_ok=$'\e[32m' _c_warn=$'\e[33m' _c_err=$'\e[31m' _c_bold=$'\e[1m' _c_off=$'\e[0m'
else
  _c_dim='' _c_ok='' _c_warn='' _c_err='' _c_bold='' _c_off=''
fi

_pr_log() {
  [[ $PR_DRY_RUN == 1 ]] && return 0
  mkdir -p "$PR_STATE" 2>/dev/null && chmod 700 "$PR_STATE" 2>/dev/null
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$PR_MODULE" "$*" >>"$PR_LOG" 2>/dev/null || true
}

pr_step() { printf '%s==>%s %s%s%s\n' "$_c_ok" "$_c_off" "$_c_bold" "$*" "$_c_off"; _pr_log "step: $*"; }
pr_say()  { printf '    %s\n' "$*"; _pr_log "$*"; }
pr_warn() { printf '    %s! %s%s\n' "$_c_warn" "$*" "$_c_off" >&2; _pr_log "warn: $*"; }
pr_die()  { printf '%sError:%s %s\n' "$_c_err" "$_c_off" "$*" >&2; _pr_log "error: $*"; exit 1; }

# Record something the user should know about (a skip, a manual step).
pr_note() { PR_NOTES+=("[$PR_MODULE] $*"); pr_warn "$*"; }

# Run a command, or only print it in dry-run mode.
pr_run() {
  if [[ $PR_DRY_RUN == 1 ]]; then
    printf '    %s[dry-run]%s %s\n' "$_c_dim" "$_c_off" "$*"
    return 0
  fi
  _pr_log "run: $*"
  "$@"
}

# Same as pr_run, as root.
pr_sudo() {
  if [[ $EUID -eq 0 ]]; then pr_run "$@"; else pr_run sudo "$@"; fi
}

pr_have() { command -v "$1" >/dev/null 2>&1; }

# Ask yes/no. Default answer is the second argument (y or n). --yes answers y.
pr_confirm() {
  local prompt=$1 def=${2:-y} reply
  [[ $PR_YES == 1 ]] && return 0
  [[ -t 0 ]] || { [[ $def == y ]]; return; }
  if pr_have gum; then
    if [[ $def == y ]]; then gum confirm "$prompt"; else gum confirm --default=false "$prompt"; fi
    return
  fi
  read -r -p "    $prompt [$([[ $def == y ]] && echo Y/n || echo y/N)] " reply
  reply=${reply:-$def}
  [[ $reply == [yY]* ]]
}

# Run an installer script published by a third party (tailscale.com, mise.run).
# Never automatic: --yes and non-interactive runs skip it unless
# --allow-remote-scripts was given. The script is downloaded in full first, so
# a cut-off download is never run.
# Usage: pr_remote_script URL [ARG...]
pr_remote_script() {
  local url=$1
  shift
  if [[ ${PR_ALLOW_REMOTE:-0} != 1 ]]; then
    if [[ $PR_YES == 1 || ! -t 0 ]]; then
      pr_note "skipped the installer from $url (re-run with --allow-remote-scripts, or interactively)"
      return 1
    fi
    pr_confirm "Run the official installer from $url?" n || return 1
  fi
  if [[ $PR_DRY_RUN == 1 ]]; then pr_run sh "<$url>" "$@"; return 0; fi
  local tmp rc
  tmp=$(mktemp) || return 1
  curl -fsSL --proto '=https' --tlsv1.2 -o "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  _pr_log "run: sh <$url> $*"
  sh "$tmp" "$@"
  rc=$?
  rm -f "$tmp"
  return $rc
}

# Ask for a value. Prints the answer. Non-interactive runs get the default.
pr_ask() {
  local prompt=$1 def=${2:-} reply
  if [[ $PR_YES == 1 || ! -t 0 ]]; then printf '%s' "$def"; return; fi
  if pr_have gum; then
    gum input --prompt "$prompt: " --value "$def"
    return
  fi
  read -r -p "    $prompt [$def] " reply
  printf '%s' "${reply:-$def}"
}

# Let the user untick items from a list (all ticked to start). Prints the
# kept items, one per line. Non-interactive runs keep everything.
# Usage: mapfile -t kept < <(pr_choose "Header" item...)
pr_choose() {
  local header=$1
  shift
  if [[ $PR_YES == 1 || ! -t 0 ]] || ! pr_have gum; then
    printf '%s\n' "$@"
    return
  fi
  gum choose --no-limit --height 20 --selected '*' --header "$header (space toggles, enter confirms)" "$@"
}

# ---------------------------------------------------------------------------
# Machine detection
# ---------------------------------------------------------------------------

PR_FAMILY='' PR_DISTRO='' PR_ARCH='' PR_GPU='' PR_HYPRLAND=0 PR_OMARCHY=0 PR_SYSTEMD=0

pr_detect() {
  local id='' like=''
  if [[ -r ${PR_OS_RELEASE:-/etc/os-release} ]]; then
    # shellcheck disable=SC1090
    id=$(. "${PR_OS_RELEASE:-/etc/os-release}"; echo "${ID:-}")
    # shellcheck disable=SC1090
    like=$(. "${PR_OS_RELEASE:-/etc/os-release}"; echo "${ID_LIKE:-}")
  fi
  PR_DISTRO=${id:-unknown}
  case " $id $like " in
    *" arch "* | *" endeavouros "* | *" cachyos "* | *" manjaro "*) PR_FAMILY=arch ;;
    *" debian "* | *" ubuntu "*) PR_FAMILY=debian ;;
    *" fedora "* | *" rhel "* | *" centos "*) PR_FAMILY=fedora ;;
    *" opensuse"* | *" suse "* | *" sles "*) PR_FAMILY=suse ;;
    *) PR_FAMILY=unknown ;;
  esac
  if [[ $PR_FAMILY == arch ]] && { pr_have omarchy || [[ -d /usr/share/omarchy ]]; }; then
    PR_OMARCHY=1
  fi
  [[ -n ${PR_FORCE_OMARCHY:-} ]] && PR_OMARCHY=$PR_FORCE_OMARCHY

  PR_ARCH=$(uname -m)

  PR_GPU=none
  if [[ -d /proc/driver/nvidia ]] || lspci 2>/dev/null | grep -qiE 'vga.*nvidia|3d.*nvidia'; then
    PR_GPU=nvidia
  elif lspci 2>/dev/null | grep -qiE '(vga|display).*(amd|ati|radeon)'; then
    PR_GPU=amd
  elif lspci 2>/dev/null | grep -qiE 'vga.*intel'; then
    PR_GPU=intel
  fi

  if pr_have Hyprland || pr_have hyprctl; then PR_HYPRLAND=1; fi
  [[ -d /run/systemd/system ]] && PR_SYSTEMD=1
  return 0
}

pr_family_label() {
  local l=$PR_FAMILY
  [[ $PR_OMARCHY == 1 ]] && l=omarchy
  printf '%s (%s, %s)' "$l" "$PR_DISTRO" "$PR_ARCH"
}

# Tiers a module can declare:
#   omarchy    needs Omarchy
#   arch       any Arch-based distro (Omarchy included)
#   hyprland   any distro running Hyprland
#   any        every supported distro
# Prints the reason and fails when the tier does not fit this machine.
pr_tier_ok() {
  case $1 in
    omarchy)  [[ $PR_OMARCHY == 1 ]] || { echo "needs Omarchy"; return 1; } ;;
    arch)     [[ $PR_FAMILY == arch ]] || { echo "needs an Arch-based distro"; return 1; } ;;
    hyprland) [[ $PR_HYPRLAND == 1 ]] || { echo "needs Hyprland"; return 1; } ;;
    any)      [[ $PR_FAMILY != unknown ]] || { echo "distro '$PR_DISTRO' is not supported"; return 1; } ;;
    *)        echo "unknown tier '$1'"; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Packages
#
# core/packages.map maps one generic name to each family:
#   name   arch   debian   fedora   suse
# A cell lists alternatives separated by "|", tried in order; the first one
# the distro can provide wins. Each alternative is one or more packages joined
# with ",". Prefixes: aur: (Arch User Repository, via yay or paru),
# flatpak: (Flathub app id). "-" means not available on that family.
# ---------------------------------------------------------------------------

_pr_map_column() {
  case $PR_FAMILY in
    arch) echo 2 ;; debian) echo 3 ;; fedora) echo 4 ;; suse) echo 5 ;; *) echo 0 ;;
  esac
}

# Print the map cell for a generic name on this family ("" when unmapped).
pr_pkg_cell() {
  local col
  col=$(_pr_map_column)
  [[ $col == 0 ]] && return 0
  awk -v n="$1" -v c="$col" '$0 !~ /^[[:space:]]*#/ && $1 == n { print $c; exit }' "$PR_MAP"
}

_pr_apt_updated=0
_pr_native_available() {
  local p=$1
  case $PR_FAMILY in
    arch) pacman -Si "$p" >/dev/null 2>&1 ;;
    debian)
      if [[ $_pr_apt_updated == 0 && $PR_DRY_RUN == 0 ]]; then
        sudo apt-get update -qq >/dev/null 2>&1 || true
        _pr_apt_updated=1
      fi
      apt-cache show "$p" >/dev/null 2>&1 ;;
    fedora) dnf -q info "$p" >/dev/null 2>&1 ;;
    suse) zypper -q se -x "$p" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

_pr_native_installed() {
  local p=$1
  case $PR_FAMILY in
    arch) pacman -T "$p" >/dev/null 2>&1 ;; # also true when another package provides it
    debian) dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' ;;
    fedora | suse) rpm -q "$p" >/dev/null 2>&1 || rpm -q --whatprovides "$p" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pr_aur_helper() {
  if pr_have yay; then echo yay; elif pr_have paru; then echo paru; else return 1; fi
}

# Install yay from the AUR when no helper is present (Arch only, never as root).
pr_ensure_aur_helper() {
  pr_aur_helper >/dev/null && return 0
  [[ $PR_FAMILY == arch ]] || return 1
  [[ $EUID -ne 0 ]] || { pr_warn "AUR helpers cannot be built as root"; return 1; }
  pr_say "Installing yay (AUR helper)"
  pr_sudo pacman -S --needed --noconfirm base-devel git || return 1
  [[ $PR_DRY_RUN == 1 ]] && return 0
  local dir
  dir=$(mktemp -d) || return 1
  git clone -q --depth 1 https://aur.archlinux.org/yay-bin.git "$dir/yay-bin" &&
    (cd "$dir/yay-bin" && makepkg -si --noconfirm --needed)
  local rc=$?
  rm -rf "$dir"
  return $rc
}

pr_ensure_flatpak() {
  if ! pr_have flatpak; then
    case $PR_FAMILY in
      arch) pr_sudo pacman -S --needed --noconfirm flatpak ;;
      debian) pr_sudo apt-get install -y flatpak ;;
      fedora) pr_sudo dnf install -y flatpak ;;
      suse) pr_sudo zypper -n in flatpak ;;
      *) return 1 ;;
    esac || return 1
  fi
  [[ $PR_DRY_RUN == 1 ]] && return 0
  flatpak remotes --columns=name 2>/dev/null | grep -qx flathub ||
    pr_sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
}

# Pick the alternative for one generic name. Prints "kind<TAB>pkg,pkg" where
# kind is native, aur or flatpak; prints nothing when unavailable.
pr_pkg_resolve() {
  local cell alt kind list p ok
  cell=$(pr_pkg_cell "$1")
  [[ -z $cell || $cell == - ]] && return 0
  IFS='|' read -r -a alts <<<"$cell"
  # An alternative already on the machine wins, so a second, conflicting
  # one (github-desktop vs github-desktop-bin) is never pulled in.
  for alt in "${alts[@]}"; do
    case $alt in
      aur:*) kind=aur list=${alt#aur:} ;;
      flatpak:*) kind=flatpak list=${alt#flatpak:} ;;
      *) kind=native list=$alt ;;
    esac
    [[ $list == - ]] && continue
    ok=1
    IFS=',' read -r -a pkgs <<<"$list"
    for p in "${pkgs[@]}"; do
      if [[ $kind == flatpak ]]; then
        pr_have flatpak && flatpak info "$p" >/dev/null 2>&1 || { ok=0; break; }
      else
        _pr_native_installed "$p" || { ok=0; break; }
      fi
    done
    if [[ $ok == 1 ]]; then
      printf '%s\t%s\n' "$kind" "$list"
      return 0
    fi
  done
  for alt in "${alts[@]}"; do
    case $alt in
      aur:*) kind=aur list=${alt#aur:} ;;
      flatpak:*) kind=flatpak list=${alt#flatpak:} ;;
      *) kind=native list=$alt ;;
    esac
    [[ $list == - ]] && continue
    ok=1
    case $kind in
      native)
        IFS=',' read -r -a pkgs <<<"$list"
        for p in "${pkgs[@]}"; do
          _pr_native_installed "$p" || _pr_native_available "$p" || { ok=0; break; }
        done ;;
      aur) [[ $PR_FAMILY == arch ]] || ok=0 ;;
      flatpak) : ;; # Flathub ids are assumed valid; install reports a bad one.
    esac
    if [[ $ok == 1 ]]; then
      printf '%s\t%s\n' "$kind" "$list"
      return 0
    fi
  done
}

# Install packages by generic name. Unavailable ones are skipped with a note.
# Usage: pr_pkg name [name...]
pr_pkg() {
  local name res kind list p
  local -a native=() aur=() flat=()
  for name in "$@"; do
    res=$(pr_pkg_resolve "$name")
    if [[ -z $res ]]; then
      pr_note "package '$name' is not available on $(pr_family_label); skipped"
      continue
    fi
    kind=${res%%$'\t'*} list=${res#*$'\t'}
    IFS=',' read -r -a pkgs <<<"$list"
    for p in "${pkgs[@]}"; do
      case $kind in
        native) _pr_native_installed "$p" || native+=("$p") ;;
        aur) _pr_native_installed "$p" || aur+=("$p") ;;
        flatpak) flatpak info "$p" >/dev/null 2>&1 || flat+=("$p") ;;
      esac
    done
  done

  if ((${#native[@]})); then
    pr_say "Installing: ${native[*]}"
    case $PR_FAMILY in
      arch) pr_sudo pacman -S --needed --noconfirm "${native[@]}" ;;
      debian) pr_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${native[@]}" ;;
      fedora) pr_sudo dnf install -y "${native[@]}" ;;
      suse) pr_sudo zypper -n in "${native[@]}" ;;
    esac || pr_note "some packages failed to install: ${native[*]}"
  fi
  if ((${#aur[@]})); then
    if pr_ensure_aur_helper; then
      pr_say "Installing (AUR): ${aur[*]}"
      local helper
      helper=$(pr_aur_helper || echo yay)
      pr_run "$helper" -S --needed --noconfirm "${aur[@]}" || pr_note "AUR install failed: ${aur[*]}"
    else
      pr_note "no AUR helper; skipped ${aur[*]}"
    fi
  fi
  if ((${#flat[@]})); then
    if pr_ensure_flatpak; then
      pr_say "Installing (Flathub): ${flat[*]}"
      pr_sudo flatpak install -y --noninteractive flathub "${flat[@]}" || pr_note "Flatpak install failed: ${flat[*]}"
    else
      pr_note "Flatpak unavailable; skipped ${flat[*]}"
    fi
  fi
  return 0
}

pr_pkg_installed() { _pr_native_installed "$1"; }

# ---------------------------------------------------------------------------
# Ledger: one line per change, so status and uninstall know what was done.
#   module <TAB> kind <TAB> target <TAB> backup <TAB> sha256
# kind: file, rootfile, block, rootblock, unit, rootunit, dir
# backup: path of the saved original, "-" when the target did not exist, or
#         "=" when it already held exactly this content (left in place on undo).
# ---------------------------------------------------------------------------

# Prints the file's sha256, or "-" when it cannot be read (never empty: the
# ledger is tab-separated and read would collapse an empty field).
_pr_sha() {
  local s
  s=$(sha256sum "$1" 2>/dev/null) && s=${s%% *}
  printf '%s' "${s:--}"
}

_pr_ledger_get() { # target -> prints the existing line for this module+target
  [[ -f $PR_LEDGER ]] || return 1
  awk -F'\t' -v m="$PR_MODULE" -v t="$1" '$1 == m && $3 == t { print; found=1 } END { exit !found }' "$PR_LEDGER"
}

_pr_ledger_set() { # kind target backup sha
  [[ $PR_DRY_RUN == 1 ]] && return 0
  mkdir -p "$PR_STATE" && chmod 700 "$PR_STATE"
  local tmp
  tmp=$(mktemp "$PR_STATE/.ledger.XXXXXX")
  if [[ -f $PR_LEDGER ]]; then
    awk -F'\t' -v m="$PR_MODULE" -v t="$2" '!($1 == m && $3 == t)' "$PR_LEDGER" >"$tmp"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$PR_MODULE" "$1" "$2" "$3" "$4" >>"$tmp"
  mv "$tmp" "$PR_LEDGER"
}

_pr_ledger_drop() { # target
  [[ $PR_DRY_RUN == 1 || ! -f $PR_LEDGER ]] && return 0
  local tmp
  tmp=$(mktemp "$PR_STATE/.ledger.XXXXXX")
  awk -F'\t' -v m="$PR_MODULE" -v t="$1" '!($1 == m && $3 == t)' "$PR_LEDGER" >"$tmp"
  mv "$tmp" "$PR_LEDGER"
}

# Save the original of a target once (the first time this module touches it).
# Prints the backup path, or "-" when there was nothing to save.
_pr_backup() { # target root(0|1)
  local target=$1 root=$2 line backup
  if line=$(_pr_ledger_get "$target"); then
    backup=$(cut -f4 <<<"$line")
    [[ $backup != = ]] && { printf '%s' "$backup"; return 0; }
    # Recorded as "already there, same content" and now being changed: save it.
  fi
  if [[ $root == 1 ]]; then sudo test -e "$target" || { printf -- -; return 0; }
  else [[ -e $target ]] || { printf -- -; return 0; }
  fi
  backup="$PR_STATE/backup/$PR_MODULE${target}"
  if [[ $PR_DRY_RUN == 1 ]]; then printf '%s' "$backup"; return 0; fi
  mkdir -p "$(dirname "$backup")"
  chmod 700 "$PR_STATE" "$PR_STATE/backup" 2>/dev/null
  # Read as root, write as the user: the backup belongs to the user.
  # shellcheck disable=SC2024
  if [[ $root == 1 ]]; then sudo cat "$target" >"$backup"; else cp -a "$target" "$backup"; fi
  printf '%s' "$backup"
}

# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------

# Copy a file into place (never a symlink). The original is backed up first.
# Usage: pr_put SRC DEST [MODE]          files under $HOME
#        pr_put --root SRC DEST [MODE]   system files, written with sudo
pr_put() {
  local root=0
  [[ $1 == --root ]] && { root=1; shift; }
  local src=$1 dest=$2 mode=${3:-}
  [[ -f $src ]] || pr_die "missing source file: $src"
  if [[ -z $mode ]]; then
    if [[ -x $src ]]; then mode=755; else mode=644; fi
  fi
  if [[ $root == 1 ]]; then
    if sudo test -f "$dest" && sudo cmp -s "$src" "$dest"; then
      _pr_ledger_get "$dest" >/dev/null || _pr_ledger_set rootfile "$dest" = "$(_pr_sha "$src")"
      return 0
    fi
  elif [[ -f $dest ]] && cmp -s "$src" "$dest"; then
    _pr_ledger_get "$dest" >/dev/null || _pr_ledger_set file "$dest" = "$(_pr_sha "$src")"
    return 0
  fi
  local backup line
  backup=$(_pr_backup "$dest" "$root")
  # Installed before and edited since: keep the edited copy too.
  if [[ $root == 0 && -f $dest ]] && line=$(_pr_ledger_get "$dest") &&
    [[ $(cut -f5 <<<"$line") != "$(_pr_sha "$dest")" ]]; then
    local edited
    edited="$PR_STATE/backup/$PR_MODULE${dest}.edited-$(date +%Y%m%d-%H%M%S)"
    if [[ $PR_DRY_RUN == 0 ]]; then
      mkdir -p "$(dirname "$edited")" && cp -a "$dest" "$edited"
    fi
    pr_note "${dest/#$HOME/\~} was edited after install; your copy is saved as ${edited/#$HOME/\~}"
  fi
  pr_say "Writing ${dest/#$HOME/\~}"
  if [[ $root == 1 ]]; then
    pr_sudo install -D -m "$mode" "$src" "$dest" || return 1
    _pr_ledger_set rootfile "$dest" "$backup" "$(_pr_sha "$src")"
  else
    pr_run install -D -m "$mode" "$src" "$dest" || return 1
    _pr_ledger_set file "$dest" "$backup" "$(_pr_sha "$src")"
  fi
}

# Write stdin to a file through pr_put (for small generated files).
# Usage: pr_write [--root] DEST [MODE] <<<"content"
pr_write() {
  local args=()
  [[ $1 == --root ]] && { args+=(--root); shift; }
  local dest=$1 mode=${2:-644} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  pr_put "${args[@]}" "$tmp" "$dest" "$mode"
  local rc=$?
  rm -f "$tmp"
  return $rc
}

# Print FILE without the marked block ID. Fails (prints nothing) when the
# begin marker has no matching end marker, so a damaged block never makes the
# rest of the file disappear. Markers match the exact id: "pratirupa:own"
# never matches "pratirupa:own-scripts".
_pr_block_strip() { # root file id
  local root=$1 file=$2 id=$3
  { if [[ $root == 1 ]]; then sudo cat "$file" 2>/dev/null; else cat "$file" 2>/dev/null; fi; } |
    awk -v id="pratirupa:$id" '
      function mark(s) { return index(s " ", id " ") }
      mark($0) && index($0, ">>>") { if (skip) exit 2; skip=1; next }
      mark($0) && index($0, "<<<") { if (!skip) exit 2; skip=0; next }
      !skip { out = out $0 "\n" }
      END { if (skip) exit 2; printf "%s", out }'
}

# Put a marked block into a file someone else owns (hyprland.lua, kitty.conf),
# leaving the rest of the file alone. Re-running replaces the block in place.
# Usage: pr_block [--root] FILE ID COMMENT <<<"content"
#   COMMENT is the file's comment marker: "#", "--" or "//".
#   PR_BLOCK_AFTER=REGEX puts the block after the first line matching REGEX
#   (e.g. the opening "{" of a JSONC object) instead of at the end.
pr_block() {
  local root=0
  [[ $1 == --root ]] && { root=1; shift; }
  local file=$1 id=$2 cmt=$3 body tmp
  body=$(cat)
  local begin="$cmt >>> pratirupa:$id (managed by pratirupa; edits inside are replaced)"
  local end="$cmt <<< pratirupa:$id"
  tmp=$(mktemp)
  if ! _pr_block_strip "$root" "$file" "$id" >"$tmp"; then
    rm -f "$tmp"
    pr_note "${file/#$HOME/\~}: the pratirupa:$id markers are damaged; left the file alone (fix or remove them, then re-run)"
    return 1
  fi
  # Drop trailing blank lines, then add the block.
  sed -i -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
  local blockfile
  blockfile=$(mktemp)
  { echo "$begin"; printf '%s\n' "$body"; echo "$end"; } >"$blockfile"
  local at=''
  [[ -n ${PR_BLOCK_AFTER:-} ]] && at=$(grep -nE -m1 "$PR_BLOCK_AFTER" "$tmp" | cut -d: -f1)
  if [[ -n $at ]]; then
    { head -n "$at" "$tmp"; cat "$blockfile"; tail -n +"$((at + 1))" "$tmp"; } >"$tmp.new" && mv "$tmp.new" "$tmp"
  else
    { [[ -s $tmp ]] && echo; cat "$blockfile"; } >>"$tmp"
  fi
  rm -f "$blockfile"
  local same=1
  if [[ $root == 1 ]]; then sudo cmp -s "$tmp" "$file" || same=0; else cmp -s "$tmp" "$file" || same=0; fi
  if [[ $same == 1 ]]; then rm -f "$tmp"; return 0; fi
  local backup
  backup=$(_pr_backup "$file" "$root")
  pr_say "Updating ${file/#$HOME/\~} (block $id)"
  if [[ $root == 1 ]]; then
    pr_sudo install -D -m 644 "$tmp" "$file"
    _pr_ledger_set rootblock "$file" "$backup" "$id"
  else
    pr_run mkdir -p "$(dirname "$file")"
    [[ $PR_DRY_RUN == 1 ]] || cat "$tmp" >"$file"
    _pr_ledger_set block "$file" "$backup" "$id"
  fi
  rm -f "$tmp"
}

# Remove a marked block. Used by uninstall.
pr_block_remove() {
  local root=0
  [[ $1 == --root ]] && { root=1; shift; }
  local file=$1 id=$2 tmp
  if [[ $root == 1 ]]; then sudo test -f "$file" || return 0; else [[ -f $file ]] || return 0; fi
  tmp=$(mktemp)
  if ! _pr_block_strip "$root" "$file" "$id" >"$tmp"; then
    rm -f "$tmp"
    pr_note "${file/#$HOME/\~}: the pratirupa:$id markers are damaged; remove the block by hand"
    return 1
  fi
  sed -i -e ':a' -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
  if [[ $root == 1 ]]; then pr_sudo install -m 644 "$tmp" "$file"; else [[ $PR_DRY_RUN == 1 ]] || cat "$tmp" >"$file"; fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

# Enable (and start) a unit. Usage: pr_unit [--user] NAME
pr_unit() {
  local user=0
  [[ $1 == --user ]] && { user=1; shift; }
  local unit=$1
  if [[ $PR_SYSTEMD != 1 ]]; then
    pr_note "no systemd; enable $unit yourself"
    return 0
  fi
  if [[ $user == 1 ]]; then
    if systemctl --user is-enabled -q "$unit" 2>/dev/null; then return 0; fi
    pr_run systemctl --user daemon-reload
    pr_say "Enabling user unit $unit"
    pr_run systemctl --user enable --now "$unit" || pr_note "could not start user unit $unit"
    _pr_ledger_set unit "$unit" - -
  else
    if systemctl is-enabled -q "$unit" 2>/dev/null; then return 0; fi
    pr_sudo systemctl daemon-reload
    pr_say "Enabling $unit"
    pr_sudo systemctl enable --now "$unit" || pr_note "could not start $unit"
    _pr_ledger_set rootunit "$unit" - -
  fi
}

# ---------------------------------------------------------------------------
# GitHub: repos and releases
# ---------------------------------------------------------------------------

_pr_gh_api() {
  local auth=()
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL --proto '=https' "${auth[@]}" -H 'Accept: application/vnd.github+json' "https://api.github.com/$1"
}

_pr_need_jq() {
  pr_have jq && return 0
  pr_note "jq is missing; install it (or run the dev-toolchain module) for release downloads"
  return 1
}

# Newest published release tag (pre-releases included, drafts never), or nothing.
_pr_latest_tag() {
  pr_have jq || return 0
  _pr_gh_api "repos/$1/releases?per_page=10" 2>/dev/null |
    jq -r '[.[] | select(.draft | not)][0].tag_name // empty' 2>/dev/null
}

# Fetch a repo into the cache at its newest release tag (or the default branch
# when it has no releases) and reset the checkout to exactly that commit, so
# nothing left in the cache from an earlier run is ever executed. Prints the
# checkout path. Usage: pr_clone OWNER/REPO
pr_clone() {
  local repo=$1 dir="$PR_CACHE/src/${1#*/}" tag ref
  tag=$(_pr_latest_tag "$repo")
  if [[ $PR_DRY_RUN == 1 ]]; then
    printf '    %s[dry-run]%s fetch https://github.com/%s at %s\n' "$_c_dim" "$_c_off" "$repo" "${tag:-its default branch}" >&2
    printf '%s' "$dir"
    return 0
  fi
  ref=${tag:+refs/tags/$tag}
  mkdir -p "$dir"
  [[ -d $dir/.git ]] || git init -q "$dir" >&2 || return 1
  git -C "$dir" remote remove origin 2>/dev/null
  git -C "$dir" remote add origin "https://github.com/$repo.git" &&
    GIT_TERMINAL_PROMPT=0 git -C "$dir" fetch -q --depth 1 origin "${ref:-HEAD}" >&2 &&
    git -C "$dir" reset -q --hard FETCH_HEAD >&2 &&
    git -C "$dir" clean -qfdx >&2 || { pr_warn "could not download $repo"; return 1; }
  _pr_log "fetched $repo at ${tag:-HEAD} ($(git -C "$dir" rev-parse --short HEAD))"
  printf '%s' "$dir"
}

# Run a script from a pr_clone checkout as root, from a root-owned copy, so
# nothing the user (or a process running as the user) can write is executed
# as root while it runs. Usage: pr_sudo_script CHECKOUT REL_PATH [ARG...]
pr_sudo_script() {
  local dir=$1 rel=$2
  shift 2
  if [[ $PR_DRY_RUN == 1 ]]; then pr_run sudo bash "$dir/$rel" "$@"; return 0; fi
  local copy rc
  copy=$(sudo mktemp -d) || return 1
  sudo cp -a "$dir/." "$copy/" && sudo chown -R root:root "$copy" && sudo chmod -R go-w "$copy" &&
    pr_sudo bash "$copy/$rel" "$@"
  rc=$?
  sudo rm -rf "$copy"
  return $rc
}

# Find the newest release asset whose name matches a regex (pre-releases
# included, drafts never). Prints "tag<TAB>name<TAB>url".
pr_release_find() {
  local repo=$1 re=$2 json
  _pr_need_jq || return 1
  json=$(_pr_gh_api "repos/$repo/releases?per_page=15") || { pr_note "could not reach GitHub for $repo releases"; return 1; }
  jq -r --arg re "$re" '
    [ .[] | select(.draft | not) | . as $r
      | .assets[] | select(.name | test($re)) | [$r.tag_name, .name, .browser_download_url] ]
    | first // empty | @tsv' <<<"$json"
}

# Download a release asset and check it against the release's checksums:
# "<asset>.sha256" or a SHA256SUMS/checksums file. A checksum file that does
# not list the asset, or lists another hash, stops the install. A release with
# no checksum file is installed on HTTPS alone, with a note.
# Usage: pr_release_get OWNER/REPO REGEX DEST_FILE
pr_release_get() {
  local repo=$1 re=$2 dest=$3 found tag name url
  found=$(pr_release_find "$repo" "$re") || return 1
  [[ -n $found ]] || { pr_note "no release asset matching /$re/ in $repo"; return 1; }
  IFS=$'\t' read -r tag name url <<<"$found"
  if [[ $PR_DRY_RUN == 1 ]]; then
    printf '    %s[dry-run]%s download %s (%s)\n' "$_c_dim" "$_c_off" "$name" "$tag"
    return 0
  fi
  local rel own agg
  rel=$(_pr_gh_api "repos/$repo/releases/tags/$tag") || { pr_note "could not read release $tag of $repo"; return 1; }
  own=$(jq -r --arg n "$name.sha256" '.assets[] | select(.name == $n) | .browser_download_url' <<<"$rel" | head -1)
  agg=$(jq -r '.assets[] | select(.name | test("^(SHA256SUMS|sha256sums|checksums|CHECKSUMS)(\\.txt)?$")) | .browser_download_url' <<<"$rel" | head -1)

  pr_say "Downloading $name ($tag)"
  mkdir -p "$(dirname "$dest")"
  local progress=(-s)
  [[ -t 2 ]] && progress=(--progress-bar)
  curl -fL --proto '=https' "${progress[@]}" -o "$dest.part" "$url" || { rm -f "$dest.part"; return 1; }

  local want='' got sums
  if [[ -n $own ]]; then
    sums=$(curl -fsSL --proto '=https' "$own") || { rm -f "$dest.part"; pr_note "could not download $name.sha256"; return 1; }
    want=$(awk 'NR == 1 { print $1 }' <<<"$sums")
  elif [[ -n $agg ]]; then
    sums=$(curl -fsSL --proto '=https' "$agg") || { rm -f "$dest.part"; pr_note "could not download the checksum file of $repo $tag"; return 1; }
    want=$(awk -v n="$name" '{ f=$2; sub(/^\*/, "", f) } f == n { print $1; exit }' <<<"$sums")
    [[ -n $want ]] || { rm -f "$dest.part"; pr_note "$name is not listed in the checksum file of $repo $tag; not installed"; return 1; }
  fi
  if [[ -n $want ]]; then
    got=$(sha256sum "$dest.part" | cut -d' ' -f1)
    if [[ ${want,,} != "$got" ]]; then
      rm -f "$dest.part"
      pr_note "checksum mismatch for $name (expected $want, got $got); not installed"
      return 1
    fi
    pr_say "Checksum OK"
  else
    pr_note "$repo $tag publishes no checksum file; $name was checked by HTTPS only"
  fi
  mv "$dest.part" "$dest"
}

# ---------------------------------------------------------------------------
# Status and uninstall (driven by the ledger)
# ---------------------------------------------------------------------------

# Print drift for one module (or all when MODULE is empty).
pr_status() {
  local want=${1:-} m kind target backup sha now n=0
  [[ -f $PR_LEDGER ]] || { echo "Nothing installed by pratirupa yet."; return 0; }
  while IFS=$'\t' read -r m kind target backup sha; do
    [[ -n $want && $m != "$want" ]] && continue
    n=$((n + 1))
    case $kind in
      file | rootfile)
        if [[ $kind == rootfile ]]; then now=$(sudo -n sha256sum "$target" 2>/dev/null | cut -d' ' -f1); [[ -z $now && -e $target ]] && now=$(_pr_sha "$target")
        else now=$(_pr_sha "$target"); fi
        if [[ ! -e $target ]]; then printf '%-18s missing   %s\n' "$m" "$target"
        elif [[ $now != "$sha" ]]; then printf '%-18s changed   %s\n' "$m" "$target"
        else printf '%-18s ok        %s\n' "$m" "$target"; fi ;;
      block | rootblock)
        if grep -qsE "pratirupa:$sha( |$)" "$target"; then printf '%-18s ok        %s (block %s)\n' "$m" "$target" "$sha"
        else printf '%-18s missing   %s (block %s)\n' "$m" "$target" "$sha"; fi ;;
      unit)
        if systemctl --user is-enabled -q "$target" 2>/dev/null; then printf '%-18s ok        user unit %s\n' "$m" "$target"
        else printf '%-18s disabled  user unit %s\n' "$m" "$target"; fi ;;
      rootunit)
        if systemctl is-enabled -q "$target" 2>/dev/null; then printf '%-18s ok        unit %s\n' "$m" "$target"
        else printf '%-18s disabled  unit %s\n' "$m" "$target"; fi ;;
      dir)
        if [[ -e $target ]]; then printf '%-18s ok        %s\n' "$m" "$target"
        else printf '%-18s missing   %s\n' "$m" "$target"; fi ;;
    esac
  done <"$PR_LEDGER"
  ((n)) || echo "Nothing recorded for ${want:-any module}."
}

# Before undo replaces or removes a file the user edited since install, save
# their copy next to the backups.
_pr_keep_edited() { # kind target sha
  local kind=$1 target=$2 sha=$3 now edited
  if [[ $kind == rootfile ]]; then now=$(sudo sha256sum "$target" 2>/dev/null) && now=${now%% *}
  else now=$(_pr_sha "$target"); fi
  [[ -n $now && $now != - && $now != "$sha" ]] || return 0
  edited="$PR_STATE/backup/$PR_MODULE${target}.edited-$(date +%Y%m%d-%H%M%S)"
  if [[ $PR_DRY_RUN == 0 ]]; then
    mkdir -p "$(dirname "$edited")"
    # shellcheck disable=SC2024
    if [[ $kind == rootfile ]]; then sudo cat "$target" >"$edited"; else cp -a "$target" "$edited"; fi
  fi
  pr_note "${target/#$HOME/\~} was edited after install; your copy is saved as ${edited/#$HOME/\~}"
}

# Undo what the ledger recorded for the current $PR_MODULE: originals are put
# back, files that did not exist before are removed, units are disabled.
# Packages are left installed (other software may need them).
pr_undo_ledger() {
  [[ -f $PR_LEDGER ]] || return 0
  local m kind target backup sha
  local -a lines=()
  mapfile -t lines < <(awk -F'\t' -v m="$PR_MODULE" '$1 == m' "$PR_LEDGER" | tac)
  local line
  for line in "${lines[@]}"; do
    IFS=$'\t' read -r m kind target backup sha <<<"$line"
    if [[ $kind == file || $kind == rootfile ]]; then
      if [[ $backup == = ]]; then
        pr_say "Keeping ${target/#$HOME/\~} (it was there before)"
        _pr_ledger_drop "$target"
        continue
      fi
      _pr_keep_edited "$kind" "$target" "$sha"
    fi
    case $kind in
      file)
        if [[ $backup != - && -e $backup ]]; then pr_say "Restoring ${target/#$HOME/\~}"; pr_run cp -a "$backup" "$target"
        else pr_say "Removing ${target/#$HOME/\~}"; pr_run rm -f "$target"; fi ;;
      rootfile)
        if [[ $backup != - && -e $backup ]]; then pr_say "Restoring $target"; pr_sudo install -m 644 "$backup" "$target"
        else pr_say "Removing $target"; pr_sudo rm -f "$target"; fi ;;
      block) pr_say "Removing block $sha from ${target/#$HOME/\~}"; pr_block_remove "$target" "$sha" ;;
      rootblock) pr_say "Removing block $sha from $target"; pr_block_remove --root "$target" "$sha" ;;
      unit) pr_run systemctl --user disable --now "$target" 2>/dev/null || true ;;
      rootunit) pr_sudo systemctl disable --now "$target" 2>/dev/null || true ;;
      dir) pr_say "Removing ${target/#$HOME/\~}"; pr_run rm -rf "$target" ;;
    esac
    _pr_ledger_drop "$target"
  done
}

# Record a directory a module created (removed again on uninstall).
pr_track_dir() { _pr_ledger_set dir "$1" - -; }
