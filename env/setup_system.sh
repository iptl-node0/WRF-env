#!/usr/bin/env bash
# env/setup_system.sh – one-time system-level helpers
set -euo pipefail

########################################################################
# 0. Helper: ensure a line exists in a shell start-up file
########################################################################
add_line_if_missing() {
  local line="$1" file="$2"

  # Create the file if it doesn't exist
  [[ -f "$file" ]] || touch "$file"

  if ! grep -Fxq "$line" "$file"; then
    printf '\n# Added by env/setup_system.sh\n%s\n' "$line" >> "$file"
    echo "  ↳ Added to $file:"
    echo "    $line"
  else
    echo "  ↳ Already present in $file"
  fi
}

########################################################################
# 1. rig (R version manager) installer  ────────────────────────────────
########################################################################
echo "── rig (R version manager) installer ───────────────────────────"

if command -v rig &>/dev/null; then
  echo "✅ rig already installed: $(rig --version)"
else
  OS=$(uname -s)
  ARCH=$(uname -m)

  install_from_tar() {
    local url="https://github.com/r-lib/rig/releases/download/latest/rig-linux-${ARCH}-latest.tar.gz"
    echo "🔧 Installing rig from tarball …"
    curl -Ls "$url" | sudo tar -xz -C /usr/local
  }

  case "$OS" in
    Linux)
      if command -v apt-get &>/dev/null; then
        echo "🔧 Installing rig via Debian repo …"
        sudo curl -L https://rig.r-pkg.org/deb/rig.gpg \
          -o /etc/apt/trusted.gpg.d/rig.gpg
        echo "deb http://rig.r-pkg.org/deb rig main" |
          sudo tee /etc/apt/sources.list.d/rig.list >/dev/null
        sudo apt-get update -qq
        sudo apt-get install -y r-rig || install_from_tar
      elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        echo "🔧 Installing rig via RPM …"
        sudo yum install -y \
          "https://github.com/r-lib/rig/releases/download/latest/r-rig-latest-1.${ARCH}.rpm" ||
          install_from_tar
      elif command -v zypper &>/dev/null; then
        echo "🔧 Installing rig via zypper …"
        sudo zypper install -y --allow-unsigned-rpm \
          "https://github.com/r-lib/rig/releases/download/latest/r-rig-latest-1.${ARCH}.rpm" ||
          install_from_tar
      else
        echo "⚠️  Unknown Linux distro – falling back to tarball."
        install_from_tar
      fi
      ;;
    Darwin)
      if command -v brew &>/dev/null; then
        echo "🔧 Installing rig via Homebrew …"
        brew tap r-lib/rig
        brew install --cask rig
      else
        echo "⚠️  Homebrew not found – please install rig manually."
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      echo "🔧 Detected Windows – manual installation required:"
      echo "    https://github.com/r-lib/rig/releases/latest"
      ;;
    *)
      echo "⚠️  Unsupported OS ($OS). Please install rig manually."
      ;;
  esac

  command -v rig &>/dev/null \
    && echo "✅ rig installed: $(rig --version)" \
    || echo "❌ rig installation failed (install manually)."
fi

########################################################################
# 1b. Ensure direnv is installed *outside* Spack (static binary) ───────
########################################################################
echo -e "\n── direnv installer ─────────────────────────────────────────"
set -Eeuo pipefail

choose_bin_path() {
  # Prefer /usr/local/bin (system-wide) if we can write with sudo; else ~/.local/bin
  if sudo -n test -w /usr/local/bin 2>/dev/null || sudo -v >/dev/null 2>&1; then
    echo /usr/local/bin
  else
    mkdir -p "$HOME/.local/bin"
    echo "$HOME/.local/bin"
  fi
}

is_broken_direnv() {
  local d
  d="$(command -v direnv 2>/dev/null || true)"
  # Broken if missing, not executable, not an ELF, or "direnv version" fails
  if [ -z "$d" ] || [ ! -x "$d" ]; then return 0; fi
  if ! file -b "$d" | grep -q 'ELF .* executable'; then return 0; fi
  if ! "$d" version >/dev/null 2>&1; then return 0; fi
  return 1
}

ensure_local_bin_on_path() {
  local LINE='export PATH="$HOME/.local/bin:$PATH"'
  if [ -d "$HOME/.local/bin" ]; then
    add_line_if_missing "$LINE" "$HOME/.bashrc"
    add_line_if_missing "$LINE" "$HOME/.bash_profile"
    # Make it effective in the current shell too
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) : ;;
      *) export PATH="$HOME/.local/bin:$PATH" ;;
    esac
  fi
}

install_or_fix_direnv() {
  local BIN_PATH
  BIN_PATH="$(choose_bin_path)"
  echo "→ Installing direnv to: $BIN_PATH"

  if [ "$BIN_PATH" = "$HOME/.local/bin" ]; then
    ensure_local_bin_on_path
    curl -sfL https://direnv.net/install.sh | env bin_path="$BIN_PATH" bash
  else
    curl -sfL https://direnv.net/install.sh | sudo env bin_path="$BIN_PATH" bash
  fi

  # If a bad /usr/local/bin/direnv exists, and we can sudo, replace it
  if [ -f /usr/local/bin/direnv ] && ! file -b /usr/local/bin/direnv | grep -q 'ELF .* executable'; then
    if sudo -n true 2>/dev/null || sudo -v >/dev/null 2>&1; then
      echo "⚠️  Replacing broken /usr/local/bin/direnv"
      sudo install -m 0755 "$(command -v direnv)" /usr/local/bin/direnv
    else
      echo "⚠️  Found broken /usr/local/bin/direnv but no sudo. Ensuring ~/.local/bin precedes it on PATH."
      ensure_local_bin_on_path
    fi
  fi
}

if ! command -v direnv >/dev/null 2>&1 || is_broken_direnv; then
  echo "🔧 Installing (or fixing) direnv via official install.sh …"
  install_or_fix_direnv
else
  echo "✅ direnv already installed: $(direnv version)"
fi

echo "→ direnv at: $(command -v direnv || echo 'not found')"
command -v direnv >/dev/null 2>&1 && direnv version || true

########################################################################
# 2. Ensure direnv + Lmod hooks in user start-up files
########################################################################
echo -e "\n── Updating shell start-up files ─────────────────────────────"

# Define hook lines (single-line, idempotent)
DIR_HOOK='if command -v direnv >/dev/null 2>&1; then eval "$(direnv hook bash)"; fi'
LMOD_HOOK='. /etc/profile.d/lmod.sh'

# Add to bashrc and bash_profile (login + interactive)
add_line_if_missing "$DIR_HOOK"  "$HOME/.bashrc"
add_line_if_missing "$LMOD_HOOK" "$HOME/.bashrc"
add_line_if_missing "$DIR_HOOK"  "$HOME/.bash_profile"
add_line_if_missing "$LMOD_HOOK" "$HOME/.bash_profile"

########################################################################
# 3. Run repo-local installers under env/install/*.sh
########################################################################
echo -e "\n── Running repo-local installers (env/install/*.sh) ───────────"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${SCRIPT_DIR}/install"
STAMP_DIR="${SCRIPT_DIR}/.install_stamps"
mkdir -p "$STAMP_DIR"

FORCE=false
for arg in "$@"; do
  [[ "$arg" == "--force" ]] && FORCE=true
done

# Clear stamps when --force is used
if [[ "$FORCE" == true ]]; then
  rm -f "$STAMP_DIR"/*.done 2>/dev/null || true
fi


# Figure out which user to run installers as (when invoked with sudo)
pick_nonroot_user() {
  if [[ $EUID -ne 0 ]]; then
    echo "$USER"
    return
  fi
  # Prefer sudo invoker
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "$SUDO_USER"
    return
  fi
  # Fall back to repo owner
  if stat --version >/dev/null 2>&1; then
    owner="$(stat -c %U "$REPO_ROOT" 2>/dev/null || echo root)"
  else
    owner="$(stat -f %Su "$REPO_ROOT" 2>/dev/null || echo root)"
  fi
  echo "${owner:-root}"
}

RUN_AS_USER="$(pick_nonroot_user)"
echo "↳ Installer scripts will run as: ${RUN_AS_USER}"

shopt -s nullglob
scripts=( "${INSTALL_DIR}/"*.sh )
shopt -u nullglob

if ((${#scripts[@]} == 0)); then
  echo "ℹ️  No install scripts found in ${INSTALL_DIR} (nothing to do)."
else
  for s in "${scripts[@]}"; do
    base="$(basename "$s")"
    stamp="$STAMP_DIR/${base}.done"
    needs_rerun=false

    # Rerun install_library.sh if library/ is missing or incomplete
    if [[ "$base" == "install_library.sh" ]]; then
      [[ ! -d "${REPO_ROOT}/library" ]] && needs_rerun=true
      [[ ! -f "${REPO_ROOT}/library/grib2/lib/libjasper.a" ]] && needs_rerun=true
      [[ ! -d "${REPO_ROOT}/library/netcdf-links" ]] && needs_rerun=true
    fi

    if [[ -f "$stamp" && "$FORCE" == false && "$needs_rerun" == false ]]; then
      echo "↳ Skipping ${base} (already completed — use --force to re-run)"
      continue
    fi

    echo "→ Running ${base} as ${RUN_AS_USER}"

    if [[ $EUID -eq 0 ]]; then
      # run installers as the non-root user; preserve env and HOME
      if sudo -H -E -u "$RUN_AS_USER" bash "$s"; then
        touch "$stamp"
        echo "✓ Finished ${base}"
      else
        echo "❌ Failed ${base} — not stamping"
        exit 1
      fi
    else
      if bash "$s"; then
        touch "$stamp"
        echo "✓ Finished ${base}"
      else
        echo "❌ Failed ${base} — not stamping"
        exit 1
      fi
    fi
  done
fi


echo "✅  Setup complete – open a new shell (login or SLURM batch) to pick up the changes."
