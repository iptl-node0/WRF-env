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

if command -v direnv &>/dev/null; then
  echo "✅ direnv already installed: $(direnv --version)"
else
  echo "🔧 Installing direnv via official install.sh …"
  # Run the script with sudo so it can copy the binary to /usr/local/bin.
  # The script is idempotent: re-running just replaces the existing binary.
  curl -sfL https://direnv.net/install.sh | sudo bash
  if command -v direnv &>/dev/null; then
    echo "✅ direnv installed: $(direnv --version)"
  else
    echo "❌ direnv installation failed (check permissions)." >&2
    exit 1
  fi
fi

########################################################################
# 2. Ensure direnv + Lmod hooks in user start-up files
########################################################################
echo -e "\n── Updating shell start-up files ─────────────────────────────"

DIR_HOOK='eval "$(direnv hook bash)"'
LMOD_HOOK='. /etc/profile.d/lmod.sh'

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

shopt -s nullglob
scripts=( "${INSTALL_DIR}/"*.sh )
shopt -u nullglob

if ((${#scripts[@]} == 0)); then
  echo "ℹ️  No install scripts found in ${INSTALL_DIR} (nothing to do)."
else
  for s in "${scripts[@]}"; do
    stamp="$STAMP_DIR/$(basename "$s").done"
    if [[ -f "$stamp" && "$FORCE" == false ]]; then
      echo "↳ Skipping $(basename "$s") (already completed — use --force to re-run)"
      continue
    fi
    echo "→ Running $(basename "$s")"
    if bash "$s"; then
      touch "$stamp"
      echo "✓ Finished $(basename "$s")"
    else
      echo "❌ Failed $(basename "$s") — not stamping"
      exit 1
    fi
  done
fi

echo "✅  Setup complete – open a new shell (login or SLURM batch) to pick up the changes."
