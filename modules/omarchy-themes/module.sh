# shellcheck shell=bash
# The omarchy-themes collection and its Theme Customiser, through the
# collection's own installer (it also installs icons, cursors, screensaver
# art, the click-glint plugin and the "Theme Customiser" menu row), plus the
# Clinical theme kept in this repo, and the video-wallpaper engine settings.
# shellcheck disable=SC2034

MOD_DESC="Themes (Halloween Night, Monograph, Christmas 2026, Clinical) and the Theme Customiser"
MOD_TIER=omarchy
MOD_ROOT=1

THEMES_REPO=omarchy-themes
THEMES_DIR=$HOME/.config/omarchy/themes

_install_clinical() {
  local f rel
  while IFS= read -r -d '' f; do
    rel=${f#"$MOD_DIR/files/clinical/"}
    pr_put "$f" "$THEMES_DIR/clinical/$rel" 644
  done < <(find "$MOD_DIR/files/clinical" -type f -print0)
  # Swap in the theme's screensaver art while it is active.
  pr_put "$MOD_DIR/files/clinical-screensaver" "$HOME/.config/omarchy/hooks/theme-set.d/clinical-screensaver" 755
}

# OWE (Omarchy's video wallpaper engine): pause the video while any window is
# open, so moving wallpapers (Christmas 2026) cost nothing while you work.
_owe_settings() {
  local conf=$HOME/.config/owe/config.toml example=/usr/share/doc/owe/config.toml.example tmp
  pr_pkg owe-lockfeed
  [[ -f $conf || -f $example ]] || return 0
  tmp=$(mktemp)
  if [[ -f $conf ]]; then cp "$conf" "$tmp"; else cp "$example" "$tmp"; fi
  sed -i 's/^occupied_workspace = false/occupied_workspace = true/' "$tmp"
  pr_put "$tmp" "$conf" 644
  rm -f "$tmp"
  [[ $PR_DRY_RUN == 0 ]] && pr_have owe && owe reload-config >/dev/null 2>&1
  return 0
}

mod_apply() {
  local dir slugs=() kept=() d
  dir=$(pr_clone "$PR_OWNER/$THEMES_REPO") || { pr_note "could not download $THEMES_REPO"; return 1; }
  if [[ -d $dir/themes ]]; then
    for d in "$dir"/themes/*/; do slugs+=("$(basename "$d")"); done
  elif [[ $PR_DRY_RUN == 1 ]]; then
    slugs=(halloween-night monograph christmas-2026)
  fi
  slugs+=(clinical)
  mapfile -t kept < <(pr_choose "Themes to install" "${slugs[@]}")
  ((${#kept[@]})) || { pr_say "No themes picked"; return 0; }

  local collection=() s
  for s in "${kept[@]}"; do [[ $s == clinical ]] || collection+=("$s"); done
  if ((${#collection[@]})); then
    pr_run bash "$dir/install.sh" "${collection[@]}" || return 1
  fi
  [[ " ${kept[*]} " == *" clinical "* ]] && _install_clinical
  _owe_settings
  pr_note "Switch theme with: omarchy theme set <name>. Boot screen text and font: Omarchy menu > Style > Theme Customiser"
}

mod_remove() {
  local dir=$PR_CACHE/src/$THEMES_REPO d slug installed=()
  [[ -x $dir/install.sh ]] || return 0
  for d in "$dir"/themes/*/; do
    slug=$(basename "$d")
    [[ -d $THEMES_DIR/$slug ]] && installed+=("$slug")
  done
  ((${#installed[@]})) && pr_run bash "$dir/install.sh" --remove "${installed[@]}"
  return 0
}
