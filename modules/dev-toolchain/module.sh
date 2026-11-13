# shellcheck shell=bash
# Everything needed to build the apps in this family: Rust + Tauri, Flutter,
# Node, Python (uv), plus Git hosting CLIs, Docker, Android and RE tools.
# shellcheck disable=SC2034

MOD_DESC="Rust + Tauri, Flutter, Node, uv Python, gh/glab, Docker, Android tools, rizin/Ghidra, Ollama"
MOD_TIER=any
MOD_ROOT=1

FLUTTER_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/flutter-sdk/flutter

mod_apply() {
  local bin=$HOME/.local/bin
  pr_pkg build-tools git curl unzip clang nodejs github-cli glab docker lazydocker \
    android-tools apktool rizin ghidra flutter-deps tauri-deps

  # --- Rust (rustup) ----------------------------------------------------------
  if ! pr_have cargo && ! [[ -x $HOME/.cargo/bin/cargo ]]; then
    pr_pkg rustup
    if pr_have rustup || [[ $PR_DRY_RUN == 1 ]]; then
      pr_run rustup default stable
    fi
  else
    pr_say "Rust already installed"
  fi
  local cargo=cargo
  [[ -x $HOME/.cargo/bin/cargo ]] && cargo=$HOME/.cargo/bin/cargo
  if ! "$cargo" tauri --version >/dev/null 2>&1; then
    if pr_confirm "Build the Tauri CLI with cargo (takes a few minutes)?" y; then
      pr_run "$cargo" install tauri-cli --locked || pr_note "cargo install tauri-cli failed"
    fi
  fi

  # --- mise: cmake, ninja and uv at user level ---------------------------------
  if ! pr_have mise; then
    if [[ -n $(pr_pkg_resolve mise) ]]; then
      pr_pkg mise
    else
      pr_remote_script https://mise.run || pr_note "mise not installed"
    fi
  fi
  local mise=mise
  pr_have mise || mise=$bin/mise
  if [[ -x $(command -v "$mise" 2>/dev/null) || $PR_DRY_RUN == 1 ]]; then
    pr_run "$mise" use -g --yes cmake ninja uv gitleaks || pr_note "mise could not install cmake/ninja/uv/gitleaks"
    pr_note "mise: cmake, ninja, uv and gitleaks were added to your global mise config (~/.config/mise/config.toml); uninstall leaves them"
    pr_run "$mise" exec uv -- uv python install 3.11 || pr_note "uv could not install Python 3.11"
  fi

  # --- Flutter (stable channel, user install) ---------------------------------
  if [[ -x $FLUTTER_DIR/bin/flutter ]]; then
    pr_say "Flutter already installed"
  else
    pr_say "Downloading Flutter (stable)"
    pr_run mkdir -p "$(dirname "$FLUTTER_DIR")"
    pr_run git clone -q --depth 1 -b stable https://github.com/flutter/flutter.git "$FLUTTER_DIR" &&
      pr_track_dir "$FLUTTER_DIR"
  fi
  pr_run mkdir -p "$bin"
  local tool
  for tool in flutter dart; do
    if [[ ! -e $bin/$tool ]]; then
      pr_run ln -s "$FLUTTER_DIR/bin/$tool" "$bin/$tool" && pr_track_dir "$bin/$tool"
    fi
  done
  pr_note "Flutter: run 'flutter doctor' once; install Android Studio or the Android SDK there if you build for Android"

  # --- Docker: daemon starts on demand -----------------------------------------
  if pr_have docker || [[ $PR_DRY_RUN == 1 ]]; then
    pr_unit docker.socket
    pr_note "Docker: commands need sudo. 'sudo usermod -aG docker \$USER' removes that, but makes your user root-equivalent"
  fi

  # --- Ollama, matched to the GPU ---------------------------------------------
  local ollama=ollama-cpu
  case $PR_GPU in nvidia) ollama="ollama-nvidia" ;; amd) ollama="ollama-amd" ;; esac
  if pr_have ollama; then
    pr_say "Ollama already installed"
  elif [[ -n $(pr_pkg_resolve "$ollama") ]]; then
    pr_pkg "$ollama"
  else
    pr_note "Ollama: not packaged here; see https://ollama.com/download/linux"
  fi
}
