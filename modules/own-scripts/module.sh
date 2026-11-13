# shellcheck shell=bash
# Small home-made helpers.
#   cast-screen        mirror the screen to a TV (Miracast / Chromecast)   Omarchy
#   media-stay-awake   keep the screen on while any media player plays     Omarchy
#   Both Headphones    one audio output that plays on every Bluetooth
#                      headphone at once (PipeWire combine-stream)         any distro with PipeWire
# shellcheck disable=SC2034

MOD_DESC="Screen casting to TVs, stay-awake while media plays, play on two Bluetooth headphones"
MOD_TIER=any
MOD_ROOT=1

# Firewall openings for casting, only from private (home/office) networks.
# The TV connects back: RTSP on 7236, Miracast over infrastructure on 7250,
# mDNS for Chromecast discovery. DHCP (67) is open while this machine is the
# Wi-Fi Direct group owner; DHCP clients have no address yet, so it cannot be
# limited by source.
CAST_NETS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)
_cast_rules() { # allow|delete
  local verb=$1 net
  local -a del=()
  [[ $verb == delete ]] && del=(delete)
  for net in "${CAST_NETS[@]}"; do
    pr_sudo ufw "${del[@]}" allow proto tcp from "$net" to any port 7236 comment 'Miracast RTSP' >/dev/null
    pr_sudo ufw "${del[@]}" allow proto tcp from "$net" to any port 7250 comment 'Miracast over infrastructure' >/dev/null
    pr_sudo ufw "${del[@]}" allow proto udp from "$net" to any port 5353 comment 'mDNS' >/dev/null
  done
  pr_sudo ufw "${del[@]}" allow proto udp from any port 68 to any port 67 comment 'Wi-Fi Direct DHCP' >/dev/null
}

mod_apply() {
  local bin=$HOME/.local/bin

  # --- Both Headphones sink (needs PipeWire) ---------------------------------
  if pr_have pipewire || [[ -d /usr/share/pipewire ]]; then
    pr_put "$MOD_DIR/files/50-bt-combine.conf" "$HOME/.config/pipewire/pipewire.conf.d/50-bt-combine.conf"
    pr_say "'Both Headphones' output appears after: systemctl --user restart pipewire"
  else
    pr_note "PipeWire not found; skipped the Both Headphones output"
  fi

  if [[ $PR_OMARCHY != 1 ]]; then
    pr_note "cast-screen and media-stay-awake use the Omarchy shell; skipped on $(pr_family_label)"
    return 0
  fi

  # --- media-stay-awake --------------------------------------------------------
  pr_put "$MOD_DIR/files/media-stay-awake" "$bin/media-stay-awake" 755
  pr_put "$MOD_DIR/files/media-stay-awake.service" "$HOME/.config/systemd/user/media-stay-awake.service"
  pr_unit --user media-stay-awake.service

  # --- cast-screen ---------------------------------------------------------------
  pr_put "$MOD_DIR/files/cast-screen" "$bin/cast-screen" 755
  pr_pkg dnsmasq gst-cast network-displays
  systemctl is-active -q ufw 2>/dev/null && _cast_rules allow

  # "Cast Screen" in the Omarchy menu (Share section). The entry goes right
  # after the opening "{" and ends with a comma, so the JSONC stays valid
  # whatever the next line is.
  local menu=$HOME/.config/omarchy/extensions/omarchy-menu.jsonc
  if [[ -f $menu ]]; then
    PR_BLOCK_AFTER='^[[:space:]]*\{[[:space:]]*$' pr_block "$menu" own-scripts // <<'EOF'
  "trigger.share.screen": {"icon":"󰄘","label":"Cast Screen","description":"Mirror to a TV over Miracast or Chromecast","action":"cast-screen"},
EOF
  fi
  pr_note "Chromecast TVs: allow each one once with: cast-screen --trust <tv-ip>"
}

mod_remove() {
  if pr_have ufw && sudo -n true 2>/dev/null || [[ $PR_DRY_RUN == 1 ]]; then
    _cast_rules delete
  fi
  return 0
}
