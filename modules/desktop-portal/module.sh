# shellcheck shell=bash
# Let Chromium/Electron apps save sign-ins under Hyprland.
#
# Hyprland has no Secret portal of its own, and gnome-keyring's portal only
# declares itself for GNOME, so org.freedesktop.portal.Secret is missing under
# XDG_CURRENT_DESKTOP=Hyprland. Chromium and Electron apps then fall back to a
# plain-text password store and say "sign-in won't be saved on this device".
# This adds gnome-keyring as the Secret backend in a user portals.conf that
# otherwise mirrors the system one.
# shellcheck disable=SC2034

MOD_DESC="Fix 'sign-in won't be saved' in Chromium/Electron apps (Secret portal)"
MOD_TIER=hyprland
MOD_ROOT=1

mod_apply() {
  pr_pkg gnome-keyring portal-gtk

  local system=/usr/share/xdg-desktop-portal/hyprland-portals.conf
  local conf
  conf=$(
    echo "# Mirrors $system, plus a Secret backend (pratirupa: desktop-portal)."
    echo "# gnome-keyring's portal declares UseIn=gnome, so without this line"
    echo "# Chromium/Electron apps cannot store sign-ins under Hyprland."
    if [[ -f $system ]]; then
      grep -v 'org.freedesktop.impl.portal.Secret' "$system"
    else
      printf '[preferred]\ndefault=hyprland;gtk\n'
    fi
  )
  if ! grep -q '^\[preferred\]' <<<"$conf"; then conf+=$'\n[preferred]'; fi
  conf=$(awk '{ print } /^\[preferred\]/ { print "org.freedesktop.impl.portal.Secret=gnome-keyring" }' <<<"$conf")

  pr_write "$HOME/.config/xdg-desktop-portal/hyprland-portals.conf" <<<"$conf"
  pr_say "Takes effect at next login (or: systemctl --user restart xdg-desktop-portal)"
}
