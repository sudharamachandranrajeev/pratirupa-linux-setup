# shellcheck shell=bash
# The apps made in this family, from their own GitHub releases and installers.
# Each app keeps its own install logic; this module only fetches and runs it.
# shellcheck disable=SC2034

MOD_DESC="Own apps from GitHub releases: Paattu, Ganana, Granthalaya, Samriddhi, Sachiva, Chanda, Vastra and more"
MOD_TIER=any
MOD_ROOT=1

# name : repo : how : asset regex : label
#   tarball   release .tar.gz with its own install.sh
#   appimage  release .AppImage
#   repo      clone the repo and run its install.sh
APPS=(
  "paattu|paattu-music-player|repo|-|Paattu (music player)"
  "ganana|ganana-ai-usage-tracker|appimage|_amd64\\.AppImage$|Ganana (AI usage tracker)"
  "granthalaya|granthalaya-retro-reader|appimage|_amd64\\.AppImage$|Granthalaya (news and book reader)"
  "samriddhi|samriddhi-wealth-manager|appimage|_amd64\\.AppImage$|Samriddhi (wealth manager)"
  "sachiva|sachiva-admin-assistant|appimage|_amd64\\.AppImage$|Sachiva (admin assistant)"
  "arogya-swasthya|arogya-swasthya-personal-health|appimage|_amd64\\.AppImage$|Arogya Swasthya (personal health)"
  "anveshana|graha-anveshana-property-search|tarball|-linux-x64\\.tar\\.gz$|Graha Anveshana (property search)"
  "chanda|chanda-shopping-assistant|tarball|-linux-x64\\.tar\\.gz$|Chanda (shopping assistant)"
  "vastra|vastra-fashion-finds|tarball|-linux-x64\\.tar\\.gz$|Vastra (fashion finds)"
  "vinyasa|vinyasa-space-organiser|tarball|-linux-x64\\.tar\\.gz$|Vinyasa (space organiser)"
  "udyoga|udyoga-career-manager|tarball|-linux-x64\\.tar\\.gz$|Udyoga (career manager)"
  "mantri|mantri-voice-control|repo|-|Mantri (voice control, ~200 MB of models)"
)

APPIMAGE_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/pratirupa/appimages

_install_appimage() { # name repo regex label
  local name=$1 repo=$2 re=$3 label=$4
  local file=$APPIMAGE_DIR/$name.AppImage bin=$HOME/.local/bin/$name
  pr_release_get "$PR_OWNER/$repo" "$re" "$file" || return 1
  pr_run chmod 755 "$file"
  pr_run mkdir -p "$HOME/.local/bin"
  if [[ ! -e $bin || -L $bin ]]; then pr_run ln -sfn "$file" "$bin"; fi
  local title=${label%% (*} comment=${label#*(}
  comment=${comment%)}
  pr_write "$HOME/.local/share/applications/pratirupa-$name.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$title
Comment=$comment
Exec="$file"
Icon=$name
Terminal=false
Categories=Utility;
EOF
  _pr_ledger_set file "$file" - "$(_pr_sha "$file")"
}

_install_tarball() { # name repo regex
  local name=$1 repo=$2 re=$3 work
  work=$(mktemp -d)
  if pr_release_get "$PR_OWNER/$repo" "$re" "$work/app.tar.gz"; then
    if [[ $PR_DRY_RUN == 1 ]]; then
      pr_run "<release>/install.sh"
    else
      tar -xzf "$work/app.tar.gz" -C "$work" || { rm -rf "$work"; return 1; }
      local installer
      installer=$(find "$work" -maxdepth 2 -name install.sh -type f | head -1)
      if [[ -n $installer ]]; then
        bash "$installer" || { rm -rf "$work"; return 1; }
        # Recorded so uninstall removes only what this module installed.
        [[ -d $HOME/.local/lib/$name ]] && pr_track_dir "$HOME/.local/lib/$name"
      else
        pr_note "$name: release has no install.sh; skipped"
      fi
    fi
  fi
  rm -rf "$work"
}

_install_repo() { # name repo
  local name=$1 repo=$2 dir
  dir=$(pr_clone "$PR_OWNER/$repo") || { pr_note "could not download $repo"; return 1; }
  case $name in
    paattu) pr_run bash "$dir/install.sh" --yes ;;
    *) pr_run bash "$dir/install.sh" ;;
  esac
}

mod_apply() {
  if [[ $PR_ARCH != x86_64 ]]; then
    pr_note "release builds are x86_64 only; only repo-installed apps (Paattu, Mantri) will be tried"
  fi
  local entry labels=() kept=()
  for entry in "${APPS[@]}"; do labels+=("${entry##*|}"); done
  mapfile -t kept < <(pr_choose "Apps to install" "${labels[@]}")

  local needs_fuse=0 name repo how re label k picked
  for entry in "${APPS[@]}"; do
    IFS='|' read -r name repo how re label <<<"$entry"
    picked=0
    for k in "${kept[@]}"; do [[ $k == "$label" ]] && picked=1; done
    ((picked)) || continue
    [[ $how == appimage ]] && needs_fuse=1
  done
  pr_pkg curl jq git
  ((needs_fuse)) && pr_pkg fuse2
  pr_pkg libsecret

  for entry in "${APPS[@]}"; do
    IFS='|' read -r name repo how re label <<<"$entry"
    picked=0
    for k in "${kept[@]}"; do [[ $k == "$label" ]] && picked=1; done
    ((picked)) || continue
    if [[ $how != repo && $PR_ARCH != x86_64 ]]; then
      pr_note "$label: no $PR_ARCH build; skipped"
      continue
    fi
    pr_say "— $label"
    case $how in
      appimage) _install_appimage "$name" "$repo" "$re" "$label" ;;
      tarball) _install_tarball "$name" "$repo" "$re" ;;
      repo) _install_repo "$name" "$repo" ;;
    esac || pr_note "$label: install failed (see the messages above)"
  done

  pr_note "Not automated yet (no Linux release): Bhandara app and watch, Bahya Nireekshana app, Artha, Bhojana, Vahana, Vani, Brahma Suite — build them from their repos"
}

mod_remove() {
  local entry name repo how re label
  for entry in "${APPS[@]}"; do
    IFS='|' read -r name repo how re label <<<"$entry"
    case $how in
      tarball)
        # The app folder is in the ledger (removed after this); drop its launcher link.
        [[ -L $HOME/.local/bin/$name && $(readlink "$HOME/.local/bin/$name") == "$HOME/.local/lib/$name/"* ]] &&
          pr_run rm -f "$HOME/.local/bin/$name" ;;
      appimage)
        [[ -L $HOME/.local/bin/$name && $(readlink "$HOME/.local/bin/$name") == "$APPIMAGE_DIR/"* ]] &&
          pr_run rm -f "$HOME/.local/bin/$name" ;;
      repo)
        local dir=$PR_CACHE/src/$repo
        if [[ $name == paattu && -f $dir/install.sh ]]; then pr_run bash "$dir/install.sh" --uninstall
        elif [[ -n $(ls "$HOME/.local/share/$name" 2>/dev/null) ]]; then
          pr_note "$label: remove it with its own uninstaller (data is never deleted by pratirupa)"
        fi ;;
    esac
  done
}
