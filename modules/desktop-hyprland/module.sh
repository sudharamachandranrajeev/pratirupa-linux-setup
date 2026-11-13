# shellcheck shell=bash
# Touchpad, gestures, key bindings and window rules for Omarchy's Hyprland.
# shellcheck disable=SC2034

MOD_DESC="Touchpad scrolling and gestures, extra key bindings, kitty font size"
MOD_TIER=omarchy
MOD_ROOT=0

mod_apply() {
  local hypr=$HOME/.config/hypr
  [[ -f $hypr/hyprland.lua ]] || { pr_note "no ~/.config/hypr/hyprland.lua; is this Omarchy 4.5 or later?"; return 1; }

  pr_put "$MOD_DIR/files/pratirupa.lua" "$hypr/pratirupa.lua"
  pr_block "$hypr/hyprland.lua" desktop-hyprland -- <<<'require("hypr.pratirupa")'

  if [[ -f $HOME/.config/kitty/kitty.conf ]]; then
    pr_block "$HOME/.config/kitty/kitty.conf" desktop-hyprland '#' <<<'font_size 9.0'
  fi

  if [[ $PR_DRY_RUN == 0 ]] && pr_have hyprctl && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    hyprctl reload >/dev/null 2>&1 && pr_say "Hyprland reloaded"
  fi
}
