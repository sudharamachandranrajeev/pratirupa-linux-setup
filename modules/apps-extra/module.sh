# shellcheck shell=bash
# Desktop apps added on top of the base system.
# shellcheck disable=SC2034

MOD_DESC="Extra apps: browsers, Ghostty, VS Code, OBS, Kdenlive, VLC, Steam, chat, mail and more"
MOD_TIER=any
MOD_ROOT=1

# Generic names from core/packages.map, with a plain label for the picker.
APPS=(
  "brave:Brave browser"
  "zen-browser:Zen browser"
  "ghostty:Ghostty terminal"
  "vscode:Visual Studio Code"
  "obs-studio:OBS Studio (recording, streaming)"
  "kdenlive:Kdenlive video editor"
  "vlc:VLC media player"
  "steam:Steam"
  "discord:Discord"
  "telegram:Telegram"
  "thunderbird:Thunderbird mail"
  "protonmail-bridge:Proton Mail Bridge"
  "qbittorrent:qBittorrent"
  "jdownloader:JDownloader"
  "torbrowser:Tor Browser launcher"
  "rustdesk:RustDesk remote desktop"
  "wayvnc:WayVNC (share this screen over VNC)"
  "xournalpp:Xournal++ (notes, PDF annotation)"
  "github-desktop:GitHub Desktop"
  "wine:Wine + winetricks (Windows programs)"
  "waydroid:Waydroid (Android apps)"
  "claude-desktop:Claude desktop (Omarchy repo only)"
  "codex-desktop:Codex desktop (Omarchy repo only)"
  "hermes-desktop:Hermes desktop (Omarchy repo only)"
)

mod_apply() {
  local labels=() entry kept=() names=() label
  for entry in "${APPS[@]}"; do labels+=("${entry#*:}"); done
  mapfile -t kept < <(pr_choose "Apps to install" "${labels[@]}")
  for entry in "${APPS[@]}"; do
    for label in "${kept[@]}"; do
      [[ $label == "${entry#*:}" ]] && names+=("${entry%%:*}")
    done
  done
  ((${#names[@]})) || { pr_say "No apps picked"; return 0; }

  # Steam needs Arch's 32-bit [multilib] repo.
  if [[ $PR_FAMILY == arch && " ${names[*]} " == *" steam "* ]] &&
    ! grep -q '^\[multilib\]' /etc/pacman.conf; then
    pr_note "Steam skipped: enable [multilib] in /etc/pacman.conf, then run this module again"
    names=("${names[@]/steam/}")
  fi

  local n list=()
  for n in "${names[@]}"; do [[ -n $n ]] && list+=("$n"); done
  pr_pkg "${list[@]}"

  if [[ " ${list[*]} " == *" waydroid "* ]] && ! [[ -e /dev/binder || -d /dev/binderfs ]] &&
    ! grep -qs binder /proc/filesystems; then
    pr_note "Waydroid needs binder support in the kernel (linux-zen, or binder_linux-dkms); run 'waydroid init' after that"
  fi
}
