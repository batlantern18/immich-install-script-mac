#!/usr/bin/env bash
#
# uninstall-immich-mac.sh
#
# Reverses everything setup-immich-mac.sh did. Each destructive step asks
# for confirmation first - nothing gets deleted silently. Your photo
# library is treated as precious: it's the one thing this script will
# NOT touch unless you explicitly say so, twice.
#
# Run it with:
#   chmod +x uninstall-immich-mac.sh
#   ./uninstall-immich-mac.sh

set -uo pipefail   # deliberately no -e: we want to keep going even if one step fails

BOLD=$(tput bold 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
CYAN=$(tput setaf 6 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)

info()  { echo "${CYAN}==>${RESET} $*"; }
ok()    { echo "${GREEN}✔${RESET} $*"; }
warn()  { echo "${YELLOW}⚠${RESET} $*"; }
err()   { echo "${RED}✘${RESET} $*" >&2; }
header(){ echo; echo "${BOLD}$*${RESET}"; echo; }

confirm() {
  # confirm "question" -> returns 0 for yes, 1 for no. Default is No.
  local reply
  read -r -p "$1 [y/N]: " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only."
  exit 1
fi

IMMICH_DIR="$HOME/Immich"
ENV_FILE="$IMMICH_DIR/.env"

header "Immich / OrbStack / Homebrew uninstaller"
echo "This will walk through removing what setup-immich-mac.sh installed."
echo "Nothing happens without you confirming each step."
echo

# ---------------------------------------------------------------------------
# 1. Stop and remove the Immich containers
# ---------------------------------------------------------------------------
header "1/6  Immich containers"

if command -v docker >/dev/null 2>&1 && [[ -f "$IMMICH_DIR/docker-compose.yml" ]]; then
  if confirm "Stop and remove the Immich containers (server, ML, redis, postgres)?"; then
    ( cd "$IMMICH_DIR" && docker compose down )
    ok "Containers stopped and removed."
  else
    warn "Skipped. Containers (and the 'immich' project) are still running/present."
  fi
else
  warn "No docker-compose.yml found at $IMMICH_DIR/docker-compose.yml - skipping."
fi

# ---------------------------------------------------------------------------
# 2. Your data: library, database, thumbnails
# ---------------------------------------------------------------------------
header "2/6  Your photo library and database"

if [[ -f "$ENV_FILE" ]]; then
  LIBRARY_PATH="$(grep '^UPLOAD_LOCATION=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  DB_PATH="$(grep '^DB_DATA_LOCATION=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"
  THUMBS_PATH="$(grep '^THUMBS_LOCATION=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)"

  echo "These are the data folders Immich has been using:"
  echo "  Library (your photos/videos): ${LIBRARY_PATH:-not set}"
  echo "  Database:                     ${DB_PATH:-not set}"
  echo "  Thumbnails:                   ${THUMBS_PATH:-not set}"
  echo
  warn "This is your actual photo and video library. Deleting it is permanent"
  warn "and cannot be undone. The default answer here is No on purpose."
  echo

  if confirm "Do you want to permanently delete this data?"; then
    if confirm "Really sure? Type-confirm again - this deletes your library for good"; then
      [[ -n "${LIBRARY_PATH:-}" && -d "$LIBRARY_PATH" ]] && rm -rf "$LIBRARY_PATH" && ok "Deleted library at $LIBRARY_PATH"
      [[ -n "${DB_PATH:-}" && -d "$DB_PATH" ]] && rm -rf "$DB_PATH" && ok "Deleted database at $DB_PATH"
      [[ -n "${THUMBS_PATH:-}" && -d "$THUMBS_PATH" ]] && rm -rf "$THUMBS_PATH" && ok "Deleted thumbnails at $THUMBS_PATH"
    else
      warn "Not confirmed a second time - your data was left untouched."
    fi
  else
    ok "Your library, database, and thumbnails were left untouched."
  fi
else
  warn "No .env found at $ENV_FILE - can't tell where your data lives, skipping."
fi

# ---------------------------------------------------------------------------
# 3. The Immich app folder itself (compose files, .env, password, logs)
# ---------------------------------------------------------------------------
header "3/6  Immich config folder ($IMMICH_DIR)"

if [[ -d "$IMMICH_DIR" ]]; then
  echo "This removes docker-compose.yml, .env, DB_PASSWORD.txt, launcher.log,"
  echo "and start-immich.sh - i.e. everything in $IMMICH_DIR EXCEPT any data"
  echo "folders that live elsewhere (handled in the previous step)."
  if confirm "Remove $IMMICH_DIR?"; then
    rm -rf "$IMMICH_DIR"
    ok "Removed $IMMICH_DIR"
  else
    warn "Skipped."
  fi
else
  warn "$IMMICH_DIR doesn't exist - skipping."
fi

# ---------------------------------------------------------------------------
# 4. The launcher app
# ---------------------------------------------------------------------------
header "4/6  Launcher app"

for APP_PATH in "/Applications/Start Immich.app" "$HOME/Desktop/Start Immich.app"; do
  if [[ -d "$APP_PATH" ]]; then
    if confirm "Remove '$APP_PATH'?"; then
      rm -rf "$APP_PATH"
      ok "Removed $APP_PATH"
    else
      warn "Skipped $APP_PATH"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 5. OrbStack
# ---------------------------------------------------------------------------
header "5/6  OrbStack"

if command -v brew >/dev/null 2>&1 && brew list --cask orbstack >/dev/null 2>&1; then
  warn "Uninstalling OrbStack removes Docker entirely from this Mac, including"
  warn "any OTHER containers/images you may have that are unrelated to Immich."
  if confirm "Uninstall OrbStack?"; then
    brew uninstall --cask --zap orbstack
    ok "OrbStack uninstalled."
  else
    warn "Skipped - OrbStack is still installed."
  fi
else
  warn "OrbStack (via Homebrew) not found - skipping."
fi

# ---------------------------------------------------------------------------
# 6. Sleep settings
# ---------------------------------------------------------------------------
header "6/6  Sleep settings"

CURRENT_SLEEP="$(pmset -g custom 2>/dev/null | awk '/^ *sleep /{print $2; exit}')"
if [[ "$CURRENT_SLEEP" == "0" ]]; then
  echo "This Mac is currently set to never sleep (set by setup-immich-mac.sh)."
  if confirm "Restore normal sleep behavior (sleep after 30 min, display after 10 min, disk sleep enabled)?"; then
    sudo pmset -a sleep 30
    sudo pmset -a disksleep 10
    sudo pmset -a displaysleep 10
    ok "Sleep settings restored to typical defaults."
  else
    warn "Left as never-sleep. Change anytime with: sudo pmset -a sleep 30 disksleep 10 displaysleep 10"
  fi
else
  ok "Sleep settings don't look modified - skipping."
fi

# ---------------------------------------------------------------------------
# Optional: Homebrew itself
# ---------------------------------------------------------------------------
header "Optional: Homebrew"

if command -v brew >/dev/null 2>&1; then
  warn "Homebrew manages more than just this setup - uninstalling it removes"
  warn "EVERYTHING you've installed with brew, not just OrbStack-related bits."
  if confirm "Uninstall Homebrew entirely too?"; then
    NONINTERACTIVE=1 /bin/bash -c \
      "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
    for PROFILE in "$HOME/.zprofile" "$HOME/.bash_profile"; do
      if [[ -f "$PROFILE" ]] && grep -q "brew shellenv" "$PROFILE" 2>/dev/null; then
        sed -i '' '/brew shellenv/d' "$PROFILE"
        ok "Cleaned up the Homebrew line from $PROFILE"
      fi
    done
    ok "Homebrew uninstalled."
  else
    ok "Homebrew left in place."
  fi
else
  warn "Homebrew not found - skipping."
fi

header "Done"
echo "Uninstall steps complete. Anything you chose to skip was left as-is."
