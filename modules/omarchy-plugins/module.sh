# shellcheck shell=bash
# Home-made Omarchy shell plugins (bar widgets and services), each from its
# own public repo, plus the bar look.
# shellcheck disable=SC2034

MOD_DESC="Bar widgets: battery ring, storage ring, AI usage, network monitor, notifications, two-headphones toggle"
MOD_TIER=omarchy
MOD_ROOT=1

PLUGINS_DIR=$HOME/.config/omarchy/plugins

# key | label
PLUGINS=(
  "battery-ring|Battery Ring (charge ring instead of the battery icon)"
  "bhandara|Bhandara storage ring"
  "ganana|Ganana AI usage ring"
  "nireekshana|Bahya Nireekshana network monitor (+ OpenSnitch rules, vnstat, nethogs)"
  "boss|BOSS notification manager (replaces the built-in notifications)"
  "dual-headphones|Both Headphones toggle"
)

_on_bar() { grep -qs "\"$1\"" "$HOME/.config/omarchy/shell.json"; }

# Copy a plugin folder into the shell and put it on the bar.
_copy_plugin() { # src-folder id before-id
  local src=$1 id=$2 before=$3 f
  [[ -f $src/manifest.json || $PR_DRY_RUN == 1 ]] || { pr_note "$id: no manifest in $src"; return 1; }
  if [[ $PR_DRY_RUN == 1 && ! -d $src ]]; then
    pr_run "copy $id to ${PLUGINS_DIR/#$HOME/\~}/$id"
  else
    for f in "$src"/*; do
      [[ -f $f ]] && pr_put "$f" "$PLUGINS_DIR/$id/$(basename "$f")" 644
    done
  fi
  pr_run omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  _on_bar "$id" || pr_run omarchy bar put "$id" --before "$before" || pr_run omarchy plugin enable "$id"
}

_battery_ring() {
  if [[ ! -d $PLUGINS_DIR/battery-ring.bar ]]; then
    pr_run omarchy plugin add "https://github.com/$PR_OWNER/omarchy-battery-ring.git" --yes || return 1
  fi
  _on_bar battery-ring.bar || pr_run omarchy bar put battery-ring.bar --after omarchy.power
  # The ring replaces the stock battery widget.
  if _on_bar omarchy.power || [[ $PR_DRY_RUN == 1 ]]; then
    pr_run omarchy plugin disable omarchy.power || true
  fi
}

_bhandara() {
  local dir
  dir=$(pr_clone "$PR_OWNER/bhandara-storage-monitor") || return 1
  _copy_plugin "$dir/omarchy/bhandara.bar" bhandara.bar battery-ring.bar
}

_ganana() {
  local dir
  dir=$(pr_clone "$PR_OWNER/ganana-ai-usage-tracker") || return 1
  _copy_plugin "$dir/integrations/omarchy/ganana.usage" ganana.usage omarchy.audio
}

_nireekshana() {
  local dir
  dir=$(pr_clone "$PR_OWNER/bahya-nireekshana-network-monitor") || return 1
  pr_sudo_script "$dir" omarchy/install.sh || pr_note "Nireekshana system side failed; see the messages above"
  pr_run bash "$dir/omarchy/install-plugin.sh"
}

_boss() {
  local dir
  dir=$(pr_clone "$PR_OWNER/boss-notification-manager") || return 1
  pr_run bash "$dir/install.sh" ||
    pr_note "BOSS refused this Omarchy version; run '$dir/install.sh --force' to try anyway"
}

_dual_headphones() {
  _copy_plugin "$MOD_DIR/files/dual-headphones" pratirupa.dual-headphones omarchy.audio
}

mod_apply() {
  pr_have omarchy || { pr_note "omarchy command not found"; return 1; }
  local entry labels=() kept=() key label k
  for entry in "${PLUGINS[@]}"; do labels+=("${entry#*|}"); done
  mapfile -t kept < <(pr_choose "Bar widgets to install" "${labels[@]}")

  for entry in "${PLUGINS[@]}"; do
    key=${entry%%|*} label=${entry#*|}
    for k in "${kept[@]}"; do
      [[ $k == "$label" ]] || continue
      pr_say "— $label"
      case $key in
        battery-ring) _battery_ring ;;
        bhandara) _bhandara ;;
        ganana) _ganana ;;
        nireekshana) _nireekshana ;;
        boss) _boss ;;
        dual-headphones) _dual_headphones ;;
      esac || pr_note "$label: install failed (see the messages above)"
    done
  done

  pr_run omarchy bar background glassy >/dev/null || true

  if ! pr_have voxtype; then
    pr_note "Dictation (Voxtype) is not installed: Omarchy menu > Install > Dictation"
  fi
  pr_note "Paattu and Mantri bar widgets come with those apps (module own-apps)"
}

mod_remove() {
  if [[ -d $PLUGINS_DIR/battery-ring.bar ]]; then
    pr_run omarchy plugin remove battery-ring.bar --yes || true
    pr_run omarchy plugin enable omarchy.power || true
  fi
  local id
  for id in bhandara.bar ganana.usage pratirupa.dual-headphones; do
    [[ -d $PLUGINS_DIR/$id ]] && pr_run omarchy plugin disable "$id" 2>/dev/null
  done
  pr_note "Nireekshana and BOSS have their own uninstallers in ${PR_CACHE/#$HOME/\~}/src"
  return 0
}
