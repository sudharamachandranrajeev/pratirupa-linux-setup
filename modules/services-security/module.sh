# shellcheck shell=bash
# Firewall, per-app network control, private network, file sync, usage stats.
# Nothing personal is copied: no Tailscale login, no Syncthing device IDs or
# folders, no firewall rules for specific addresses.
# shellcheck disable=SC2034

MOD_DESC="ufw firewall, OpenSnitch, Tailscale (not logged in), Syncthing, vnstat, SMART tools"
MOD_TIER=any
MOD_ROOT=1

mod_apply() {
  pr_pkg ufw opensnitch syncthing vnstat smartmontools nethogs

  # --- firewall: block incoming, allow outgoing -----------------------------
  if systemctl is-active -q firewalld 2>/dev/null; then
    pr_note "firewalld is active; leaving it in charge instead of ufw"
  elif pr_have ufw || [[ $PR_DRY_RUN == 1 ]]; then
    if [[ -n ${SSH_CONNECTION:-} ]]; then
      pr_say "Connected over SSH: allowing SSH before turning the firewall on"
      # Allow the port this session came in on (SSH_CONNECTION ends with it).
      local port=${SSH_CONNECTION##* }
      [[ $port =~ ^[0-9]+$ ]] || port=22
      pr_sudo ufw allow "$port/tcp" comment 'SSH (this session)' >/dev/null
    fi
    # /etc/ufw/ufw.conf is world-readable; 'ufw status' would need root.
    if ! grep -qs '^ENABLED=yes' /etc/ufw/ufw.conf; then
      pr_sudo ufw default deny incoming
      pr_sudo ufw default allow outgoing
      pr_sudo ufw --force enable
    fi
    pr_unit ufw.service
  fi

  # --- OpenSnitch: asks before an unknown app connects ----------------------
  if pr_pkg_installed opensnitch || [[ $PR_DRY_RUN == 1 ]]; then
    pr_unit opensnitchd.service
  fi

  # --- Tailscale: installed and running, joining a network is up to you ----
  if [[ -n $(pr_pkg_resolve tailscale) ]]; then
    pr_pkg tailscale
  elif ! pr_have tailscale; then
    pr_remote_script https://tailscale.com/install.sh || pr_note "Tailscale not installed"
  fi
  if pr_have tailscale || [[ $PR_DRY_RUN == 1 ]]; then
    pr_unit tailscaled.service
    pr_note "Tailscale is installed but not logged in. Join your network with: sudo tailscale up"
  fi

  # --- Syncthing for this user; pair devices in its web UI -------------------
  if pr_have syncthing || [[ $PR_DRY_RUN == 1 ]]; then
    pr_unit --user syncthing.service
    pr_say "Syncthing web UI: http://127.0.0.1:8384 (pair your devices there)"
  fi

  # --- vnstat: network usage history ----------------------------------------
  if pr_have vnstat || [[ $PR_DRY_RUN == 1 ]]; then
    pr_unit vnstat.service
  fi
}
