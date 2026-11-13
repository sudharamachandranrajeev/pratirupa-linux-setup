#!/usr/bin/env bash
# Pratirupa: put this setup on any Linux machine.
#
#   ./setup.sh                        pick modules from a list and install them
#   ./setup.sh install [MODULE...]    install the named modules (all that fit when none named)
#   ./setup.sh list                   show every module and whether it fits this machine
#   ./setup.sh status [MODULE]        show what was installed and what changed since
#   ./setup.sh uninstall MODULE...    put back the files a module replaced
#   ./setup.sh capture                (maintainers) compare this machine with Omarchy's defaults
#
# Options:
#   --dry-run   show what would happen, change nothing
#   --yes       do not ask; take the default answers
#   --allow-remote-scripts
#               let modules run third-party installers (tailscale.com,
#               mise.run) without asking; otherwise they ask, and --yes skips them
#
# One-line install (clones to ~/.local/share/pratirupa, then runs from there):
#   curl -fsSL https://raw.githubusercontent.com/sudharamachandranrajeev/pratirupa-linux-setup/main/setup.sh | bash

set -uo pipefail

REPO_URL=https://github.com/sudharamachandranrajeev/pratirupa-linux-setup.git
# Piped from curl (no BASH_SOURCE), or no checkout next to us: fetch one into
# ~/.local/share/pratirupa and re-run it from there with the terminal attached.
# Never source a core/ that happens to sit in the current directory.
here=''
[[ -n ${BASH_SOURCE[0]:-} && -f ${BASH_SOURCE[0]} ]] && here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -z $here || ! -f $here/core/pratirupa.sh ]]; then
  dest=${XDG_DATA_HOME:-$HOME/.local/share}/pratirupa
  command -v git >/dev/null || { echo "Pratirupa needs git. Install it, then run this again." >&2; exit 1; }
  if [[ -d $dest/.git ]]; then git -C "$dest" pull -q --ff-only
  else git clone -q --depth 1 "$REPO_URL" "$dest"
  fi || { echo "Could not download Pratirupa." >&2; exit 1; }
  if [[ -r /dev/tty ]]; then exec bash "$dest/setup.sh" "$@" </dev/tty; fi
  exec bash "$dest/setup.sh" "$@"
fi

PR_ROOT=$here
# shellcheck source=core/pratirupa.sh
. "$here/core/pratirupa.sh"

# Install order: tools and apps first, then the desktop pieces that use them.
ORDER=(
  dev-toolchain
  apps-extra
  services-security
  own-apps
  own-scripts
  desktop-portal
  desktop-hyprland
  omarchy-themes
  omarchy-plugins
)

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

# Read a module's MOD_* fields without running it.
mod_field() { # module field
  (
    # shellcheck disable=SC1090
    . "$here/modules/$1/module.sh" >/dev/null 2>&1
    eval "printf '%s' \"\${$2:-}\""
  )
}

mod_fits() { # module -> prints reason when it does not fit
  pr_tier_ok "$(mod_field "$1" MOD_TIER)"
}

known_module() { [[ -f $here/modules/$1/module.sh ]]; }

cmd_list() {
  printf '%sThis machine:%s %s\n\n' "$_c_bold" "$_c_off" "$(pr_family_label)"
  local m why
  for m in "${ORDER[@]}"; do
    if why=$(mod_fits "$m"); then
      printf '  %s✓%s %-18s %s\n' "$_c_ok" "$_c_off" "$m" "$(mod_field "$m" MOD_DESC)"
    else
      printf '  %s–%s %-18s %s%s (%s)%s\n' "$_c_dim" "$_c_off" "$m" "$_c_dim" "$(mod_field "$m" MOD_DESC)" "$why" "$_c_off"
    fi
  done
}

pick_modules() {
  local m fitting=() labels=() chosen
  for m in "${ORDER[@]}"; do
    mod_fits "$m" >/dev/null && fitting+=("$m")
  done
  ((${#fitting[@]})) || pr_die "No module fits this machine ($(pr_family_label))."
  if [[ $PR_YES == 1 || ! -t 0 ]]; then
    printf '%s\n' "${fitting[@]}"
    return
  fi
  if pr_have gum; then
    for m in "${fitting[@]}"; do labels+=("$m — $(mod_field "$m" MOD_DESC)"); done
    local selected
    selected=$(IFS=,; echo "${labels[*]}")
    chosen=$(gum choose --no-limit --height 15 --selected "$selected" \
      --header "Pick what to install (space toggles, enter confirms)" "${labels[@]}") || exit 1
    sed 's/ — .*//' <<<"$chosen"
  else
    echo "Modules that fit this machine:" >&2
    local i=1
    for m in "${fitting[@]}"; do printf '  %d) %-18s %s\n' "$i" "$m" "$(mod_field "$m" MOD_DESC)" >&2; i=$((i + 1)); done
    local reply
    read -r -p "Numbers to install (Enter = all): " reply
    if [[ -z $reply ]]; then printf '%s\n' "${fitting[@]}"; return; fi
    for i in $reply; do
      [[ $i =~ ^[0-9]+$ && $i -ge 1 && $i -le ${#fitting[@]} ]] && echo "${fitting[$((i - 1))]}"
    done
  fi
}

sudo_keepalive() {
  [[ $PR_DRY_RUN == 1 || $EUID -eq 0 ]] && return 0
  # Passwordless sudo needs no prompt. ("sudo -v" asks anyway when any other
  # sudoers rule, such as openSUSE's default, still wants a password.)
  if ! sudo -n true 2>/dev/null; then
    echo "Some steps change system files; sudo will ask for your password once."
    sudo -v || pr_die "sudo is needed for the selected modules."
  fi
  (while kill -0 $$ 2>/dev/null; do sudo -n true; sleep 50; done) 2>/dev/null &
  KEEPALIVE=$!
  trap 'kill $KEEPALIVE 2>/dev/null' EXIT
}

# Run one module in its own shell so modules cannot interfere.
run_module() { # module action
  local m=$1 action=$2 notes
  notes=$(mktemp)
  (
    PR_MODULE=$m
    PR_NOTES=()
    export PR_MODULE
    # shellcheck disable=SC1090
    . "$here/modules/$m/module.sh"
    # shellcheck disable=SC2034  # read by the module functions
    MOD_DIR=$here/modules/$m
    rc=0
    case $action in
      apply) mod_apply || rc=$? ;;
      remove)
        if declare -F mod_remove >/dev/null; then mod_remove || rc=$?; fi
        pr_undo_ledger ;;
    esac
    ((${#PR_NOTES[@]})) && printf '%s\n' "${PR_NOTES[@]}" >"$notes"
    exit "$rc"
  )
  local rc=$?
  [[ -s $notes ]] && mapfile -t -O "${#PR_NOTES[@]}" PR_NOTES <"$notes"
  rm -f "$notes"
  return $rc
}

cmd_install() {
  local mods=("$@") m why failed=()
  if ((${#mods[@]} == 0)); then mapfile -t mods < <(pick_modules); fi
  ((${#mods[@]})) || { echo "Nothing selected."; return 0; }
  for m in "${mods[@]}"; do known_module "$m" || pr_die "No module called '$m'. See: ./setup.sh list"; done

  local needs_root=0
  for m in "${mods[@]}"; do [[ $(mod_field "$m" MOD_ROOT) == 1 ]] && needs_root=1; done

  echo
  printf '%sPratirupa%s on %s%s\n' "$_c_bold" "$_c_off" "$(pr_family_label)" "$([[ $PR_DRY_RUN == 1 ]] && echo ' — dry run, nothing will change')"
  ((needs_root)) && sudo_keepalive

  for m in "${ORDER[@]}"; do
    [[ " ${mods[*]} " == *" $m "* ]] || continue
    echo
    if ! why=$(mod_fits "$m"); then
      pr_step "$m: skipped ($why)"
      PR_NOTES+=("[$m] skipped: $why")
      continue
    fi
    pr_step "$m — $(mod_field "$m" MOD_DESC)"
    run_module "$m" apply || failed+=("$m")
  done

  echo
  pr_step "Done"
  ((${#failed[@]})) && printf '    %sFailed:%s %s (details in %s)\n' "$_c_err" "$_c_off" "${failed[*]}" "${PR_LOG/#$HOME/\~}"
  if ((${#PR_NOTES[@]})); then
    echo "    Notes:"
    printf '      - %s\n' "${PR_NOTES[@]}"
  fi
  [[ $PR_DRY_RUN == 1 ]] || echo "    Check later with: ./setup.sh status"
  ((${#failed[@]} == 0))
}

cmd_uninstall() {
  (($#)) || pr_die "Name the module(s) to uninstall. See: ./setup.sh status"
  local m
  for m in "$@"; do known_module "$m" || pr_die "No module called '$m'."; done
  pr_confirm "Undo $* (restore replaced files, remove added ones; packages stay installed)?" n || exit 0
  for m in "$@"; do
    [[ $(mod_field "$m" MOD_ROOT) == 1 ]] && { sudo_keepalive; break; }
  done
  for m in "$@"; do pr_step "Uninstalling $m"; run_module "$m" remove; done
}

main() {
  [[ $EUID -ne 0 ]] || pr_die "Run Pratirupa as your normal user, not root. It asks for sudo when it needs it."
  local cmd=menu args=()
  while (($#)); do
    case $1 in
      --dry-run) PR_DRY_RUN=1 ;;
      --yes | -y) PR_YES=1 ;;
      --allow-remote-scripts) PR_ALLOW_REMOTE=1 ;;
      -h | --help | help) usage; exit 0 ;;
      capture) cmd=capture; shift; args=("$@"); break ;;
      install | list | status | uninstall) cmd=$1 ;;
      -*) pr_die "Unknown option $1" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  export PR_DRY_RUN PR_YES PR_ALLOW_REMOTE

  pr_detect
  case $cmd in
    menu | install) cmd_install "${args[@]}" ;;
    list) cmd_list ;;
    status) pr_status "${args[0]:-}" ;;
    uninstall) cmd_uninstall "${args[@]}" ;;
    capture) exec bash "$here/tools/capture.sh" "${args[@]}" ;;
  esac
}

main "$@"
