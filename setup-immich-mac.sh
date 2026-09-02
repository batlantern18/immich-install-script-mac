#!/usr/bin/env bash
#
# setup-immich-mac.sh
#
# One-shot setup for a self-hosted Immich photo server on macOS.
#
#   1. Installs Homebrew (if missing)
#   2. Completes initial Homebrew setup (PATH, shell profile)
#   3. brew update && brew upgrade
#   4. brew install --cask orbstack (gives you Docker on Mac)
#   5. Sets up Immich via Docker Compose, following
#      https://docs.immich.app/install/docker-compose
#      - asks where your LIBRARY (photo/video originals) should live
#      - asks where the SSD-backed database folder should live
#      - generates a random Postgres password
#      - asks for your timezone
#      - binds Immich to 0.0.0.0 so other devices on your Wi-Fi can reach it
#   6. Creates a double-clickable "Start Immich.app" launcher on your Desktop
#   7. Optionally disables sleep so Immich stays reachable 24/7
#
# Run it with:
#   chmod +x setup-immich-mac.sh
#   ./setup-immich-mac.sh
#
# Safe to re-run - it will reuse settings from an existing .env if found.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output helpers
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# 0. Sanity checks
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "This script is for macOS only."
  exit 1
fi

header "1/8  Homebrew"

# ---------------------------------------------------------------------------
# 1 & 2. Install Homebrew and complete initial setup
# ---------------------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  info "Homebrew not found - installing (this uses the official installer,"
  info "run non-interactively so it won't stop to ask you anything)..."
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  ok "Homebrew already installed."
fi

# Figure out where brew lives (Apple Silicon vs Intel) and load it into PATH.
if [[ -x /opt/homebrew/bin/brew ]]; then
  BREW_BIN=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
  BREW_BIN=/usr/local/bin/brew
else
  BREW_BIN="$(command -v brew)"
fi
eval "$("$BREW_BIN" shellenv)"

# Make sure future terminal sessions also get brew on PATH.
SHELL_PROFILE="$HOME/.zprofile"
[[ "$SHELL" == */bash ]] && SHELL_PROFILE="$HOME/.bash_profile"
SHELLENV_LINE="eval \"\$($BREW_BIN shellenv)\""
if ! grep -qsF "$SHELLENV_LINE" "$SHELL_PROFILE" 2>/dev/null; then
  echo "$SHELLENV_LINE" >> "$SHELL_PROFILE"
  ok "Added Homebrew to $SHELL_PROFILE"
fi

ok "Homebrew is set up ($($BREW_BIN --version | head -1))"

header "2/8  Updating Homebrew"

# ---------------------------------------------------------------------------
# 3. Update & upgrade brew
# ---------------------------------------------------------------------------
brew update
brew upgrade || true   # don't die if a formula has nothing to upgrade
ok "Homebrew is up to date."

header "3/8  Installing OrbStack"

# ---------------------------------------------------------------------------
# 4. Install OrbStack (lightweight Docker Desktop alternative for Mac)
# ---------------------------------------------------------------------------
if ! brew list --cask orbstack >/dev/null 2>&1; then
  brew install --cask orbstack
else
  ok "OrbStack already installed."
fi

# Figure out exactly where OrbStack landed and force Launch Services to
# register it right away - `open -a OrbStack` can fail silently on a fresh
# install before macOS has indexed the new app by name.
ORBSTACK_APP="/Applications/OrbStack.app"
if [[ ! -d "$ORBSTACK_APP" ]]; then
  ORBSTACK_APP="$HOME/Applications/OrbStack.app"
fi
if [[ -d "$ORBSTACK_APP" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$ORBSTACK_APP" 2>/dev/null || true
else
  err "Couldn't find OrbStack.app after installing it - check /Applications manually."
fi

info "Launching OrbStack so it can finish its first-run setup..."
if [[ -d "$ORBSTACK_APP" ]]; then
  open "$ORBSTACK_APP"
else
  open -a OrbStack || true
fi

info "Waiting for the Docker engine to come up (up to 3 minutes)..."
info "If OrbStack shows a setup or permission dialog, click through it now."
DOCKER_READY=0
for i in $(seq 1 90); do
  if docker info >/dev/null 2>&1; then
    DOCKER_READY=1
    break
  fi
  sleep 2
done

if [[ "$DOCKER_READY" -eq 1 ]]; then
  ok "Docker engine is ready."
else
  warn "Docker didn't come up automatically. OrbStack may be waiting on you"
  warn "to grant a permission or finish onboarding in its window."
  warn "Finish that, then re-run this script - it will pick up where it left off."
  exit 1
fi

header "4/8  Setting up Immich"

# ---------------------------------------------------------------------------
# 5. Immich setup - https://docs.immich.app/install/docker-compose
# ---------------------------------------------------------------------------
IMMICH_DIR="$HOME/Immich"
mkdir -p "$IMMICH_DIR"
cd "$IMMICH_DIR"

ENV_FILE="$IMMICH_DIR/.env"
COMPOSE_FILE="$IMMICH_DIR/docker-compose.yml"

if [[ -f "$ENV_FILE" ]]; then
  warn "Found an existing .env in $IMMICH_DIR - reusing it as-is."
  warn "Delete $ENV_FILE and re-run this script if you want to reconfigure from scratch."
else
  echo
  echo "${BOLD}About the two folders Immich needs:${RESET}"
  echo
  echo "  ${BOLD}Library${RESET}  - this is where your actual photos and videos are stored"
  echo "             (the originals, plus generated thumbnails/previews)."
  echo "             It gets big fast, so it should live on a drive with"
  echo "             plenty of room - ${BOLD}a large HDD is a great fit${RESET}, an SSD"
  echo "             works too if you have the space."
  echo
  echo "  ${BOLD}Database${RESET} - a small Postgres folder Immich uses to index and search"
  echo "             your library. It's accessed constantly, so it should"
  echo "             live on a ${BOLD}fast SSD${RESET} even if your library is on an HDD."
  echo
  echo "  ${BOLD}Thumbnails${RESET} - the small preview images Immich generates and displays"
  echo "             constantly while you browse. These get their own folder,"
  echo "             placed right next to the database (same SSD), so scrolling"
  echo "             through your library stays fast even if the library itself"
  echo "             is on a slower HDD."
  echo

  # --- Library location -----------------------------------------------
  DEFAULT_LIBRARY="$IMMICH_DIR/library"
  read -r -p "Where should your LIBRARY (photos/videos, ideally on an HDD) live? [$DEFAULT_LIBRARY]: " LIBRARY_PATH
  LIBRARY_PATH="${LIBRARY_PATH:-$DEFAULT_LIBRARY}"
  LIBRARY_PATH="${LIBRARY_PATH/#\~/$HOME}"
  mkdir -p "$LIBRARY_PATH"
  ok "Library will be stored at: $LIBRARY_PATH"

  # --- Database location (SSD, Documents folder by default) -----------
  DEFAULT_DB="$HOME/Documents/immich-db"
  read -r -p "Where should the DATABASE (small, keep on your SSD) live? [$DEFAULT_DB]: " DB_PATH
  DB_PATH="${DB_PATH:-$DEFAULT_DB}"
  DB_PATH="${DB_PATH/#\~/$HOME}"
  mkdir -p "$DB_PATH"
  ok "Database will be stored at: $DB_PATH"

  # --- Timezone ---------------------------------------------------------
  DEFAULT_TZ="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || true)"
  DEFAULT_TZ="${DEFAULT_TZ:-Etc/UTC}"
  echo
  echo "Timezone identifiers look like 'America/Los_Angeles' or 'Europe/London'."
  echo "Full list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
  read -r -p "What timezone should Immich use? [$DEFAULT_TZ]: " TZ_INPUT
  TZ_VALUE="${TZ_INPUT:-$DEFAULT_TZ}"
  ok "Timezone: $TZ_VALUE"

  # --- Generate a random Postgres password ------------------------------
  # Immich's docs ask for only A-Za-z0-9, no special characters.
  DB_PASSWORD="$(set +o pipefail; LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
  ok "Generated a random database password."

  # --- Download the official compose file + env template ----------------
  info "Downloading the latest docker-compose.yml and .env template from Immich..."
  curl -fsSL -o "$COMPOSE_FILE" \
    https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
  curl -fsSL -o "$ENV_FILE" \
    https://github.com/immich-app/immich/releases/latest/download/example.env

  # --- Fill in the .env file ---------------------------------------------
  # Use | as sed delimiter since paths contain /
  sed -i '' "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=${LIBRARY_PATH}|" "$ENV_FILE"
  sed -i '' "s|^DB_DATA_LOCATION=.*|DB_DATA_LOCATION=${DB_PATH}|" "$ENV_FILE"
  sed -i '' "s|^DB_PASSWORD=.*|DB_PASSWORD=${DB_PASSWORD}|" "$ENV_FILE"

  if grep -q '^# TZ=' "$ENV_FILE"; then
    sed -i '' "s|^# TZ=.*|TZ=${TZ_VALUE}|" "$ENV_FILE"
  elif grep -q '^TZ=' "$ENV_FILE"; then
    sed -i '' "s|^TZ=.*|TZ=${TZ_VALUE}|" "$ENV_FILE"
  else
    echo "TZ=${TZ_VALUE}" >> "$ENV_FILE"
  fi

  # --- Make sure Immich is reachable from other devices on the network ---
  # Docker already publishes to 0.0.0.0 by default, but we make it explicit
  # in the compose file so it's obvious and so a firewall rule is easy to reason about.
  sed -i '' "s|- '2283:2283'|- '0.0.0.0:2283:2283'|" "$COMPOSE_FILE"

  # --- Save the password somewhere the user can find it later -----------
  {
    echo "Immich database password (generated $(date)):"
    echo "$DB_PASSWORD"
    echo
    echo "This is also stored in $ENV_FILE (DB_PASSWORD=...)."
  } > "$IMMICH_DIR/DB_PASSWORD.txt"
  chmod 600 "$IMMICH_DIR/DB_PASSWORD.txt"

  ok "Wrote configuration to $ENV_FILE"
  ok "Saved a copy of the database password to $IMMICH_DIR/DB_PASSWORD.txt"
fi

# ---------------------------------------------------------------------------
# Dedicated thumbs volume, stored next to the database (same parent folder).
# Immich mounts UPLOAD_LOCATION to /data inside the container; mounting a
# second volume at the more-specific path /data/thumbs overrides just that
# subfolder, so thumbnails land on the SSD while everything else in the
# library stays wherever UPLOAD_LOCATION points (e.g. your HDD).
# This block is idempotent, so re-running the script on an older setup
# (from before thumbs were split out) will add it in automatically.
# ---------------------------------------------------------------------------
if ! grep -q '^THUMBS_LOCATION=' "$ENV_FILE"; then
  ENV_DB_PATH="$(grep '^DB_DATA_LOCATION=' "$ENV_FILE" | cut -d= -f2-)"
  THUMBS_PATH="$(dirname "$ENV_DB_PATH")/immich-thumbs"
  mkdir -p "$THUMBS_PATH"
  {
    echo ""
    echo "# Thumbnails - kept on the same (SSD) drive as the database for speed"
    echo "THUMBS_LOCATION=${THUMBS_PATH}"
  } >> "$ENV_FILE"
  ok "Thumbnails will be stored at: $THUMBS_PATH"
else
  THUMBS_PATH="$(grep '^THUMBS_LOCATION=' "$ENV_FILE" | cut -d= -f2-)"
  mkdir -p "$THUMBS_PATH"
fi

if ! grep -q 'THUMBS_LOCATION' "$COMPOSE_FILE"; then
  awk -v ins="      - \${THUMBS_LOCATION}:/data/thumbs" '
    { print }
    /\$\{UPLOAD_LOCATION\}:\/data/ && !done { print ins; done=1 }
  ' "$COMPOSE_FILE" > "$COMPOSE_FILE.tmp" && mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
  ok "Added a dedicated thumbs volume to docker-compose.yml"
fi

header "5/8  Starting Immich"

cd "$IMMICH_DIR"
docker compose pull
docker compose up -d
ok "Immich containers are starting."

header "6/8  Creating a launcher app"

# ---------------------------------------------------------------------------
# 6. A double-clickable app that starts Immich.
#
# Built with `osacompile` - the same underlying tool Automator/Script Editor
# use to turn a workflow into an "Application". This produces a proper,
# natively-formed .app bundle (with a real code signature and correct
# LaunchServices registration), which is much more reliable than a
# hand-assembled bundle. The actual logic lives in a plain shell script
# (start-immich.sh) that the compiled app just calls - so you can also run
# it directly from Terminal any time.
# ---------------------------------------------------------------------------

RUNNER="$IMMICH_DIR/start-immich.sh"

cat > "$RUNNER" <<RUNNEREOF
#!/usr/bin/env bash
# Starts (or restarts) the Immich stack and opens it in your browser.
# Run directly (bash $RUNNER) or via the "Start Immich" app.

LOG="$IMMICH_DIR/launcher.log"
echo "=== \$(date) ===" >> "\$LOG"

run() {
  # do shell script (used by the launcher app) runs with a minimal PATH that
  # doesn't include /usr/local/bin - where OrbStack's docker CLI lives - or
  # Homebrew's bin dir. Make sure both are present no matter how this runs.
  export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:\$HOME/bin:\$PATH"
  if [[ -x /opt/homebrew/bin/brew ]]; then eval "\$(/opt/homebrew/bin/brew shellenv)"; fi
  if [[ -x /usr/local/bin/brew ]]; then eval "\$(/usr/local/bin/brew shellenv)"; fi

  echo "Using docker at: \$(command -v docker || echo NOT FOUND)"
  echo "PATH is: \$PATH"

  # Bring OrbStack to the front (not hidden) - if it needs you to click
  # through a first-run permission or setup dialog, you need to actually see it.
  # Use the explicit app path rather than -a OrbStack, which can fail silently
  # if Launch Services hasn't indexed it by name for some reason.
  if [[ -d "/Applications/OrbStack.app" ]]; then
    open "/Applications/OrbStack.app"
  elif [[ -d "\$HOME/Applications/OrbStack.app" ]]; then
    open "\$HOME/Applications/OrbStack.app"
  else
    open -a OrbStack || echo "Could not find or open OrbStack.app" >&2
  fi

  echo "Waiting for the Docker engine..."
  local ready=0
  for i in \$(seq 1 90); do
    if docker info >/dev/null 2>&1; then ready=1; break; fi
    echo "  still waiting (attempt \$i/90) - if OrbStack popped up a dialog, click through it"
    sleep 2
  done
  if [[ "\$ready" -ne 1 ]]; then
    echo "Docker engine never became ready after 3 minutes." >&2
    echo "Open OrbStack manually, make sure it finishes any setup/permission prompts, then try again." >&2
    return 1
  fi
  echo "Docker engine is ready."

  cd "$IMMICH_DIR"
  docker compose up -d
  echo "--- docker compose ps ---"
  docker compose ps

  LOCAL_IP=\$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")
  osascript -e "display notification \"Immich is running at http://\$LOCAL_IP:2283\" with title \"Immich\""
  open "http://localhost:2283"
}

if run >> "\$LOG" 2>&1; then
  exit 0
else
  open -e "\$LOG"
  TAIL="\$(tail -n 15 "\$LOG" | sed 's/"/\\\\"/g')"
  osascript -e "display alert \"Immich failed to start\" message \"The log just opened in TextEdit. Last lines:\n\n\$TAIL\" as critical"
  exit 1
fi
RUNNEREOF

chmod +x "$RUNNER"

# Give the app Immich's logo as its icon, if we can fetch and convert it.
ICON_ICNS=""
ICON_PNG="$IMMICH_DIR/.immich-icon.png"
if curl -fsSL -o "$ICON_PNG" \
  "https://raw.githubusercontent.com/immich-app/immich/main/design/immich-logo.png" 2>/dev/null \
  && [[ -s "$ICON_PNG" ]]; then
  ICONSET="$IMMICH_DIR/.AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1 || true
  done
  ICON_ICNS="$IMMICH_DIR/.AppIcon.icns"
  iconutil -c icns "$ICONSET" -o "$ICON_ICNS" >/dev/null 2>&1 || ICON_ICNS=""
  rm -rf "$ICONSET" "$ICON_PNG"
fi

# The compiled app just runs start-immich.sh in the background and returns
# immediately, so the app doesn't sit there with a spinning cursor for 3 minutes.
APPLESCRIPT_SRC="$IMMICH_DIR/.start-immich.applescript"
cat > "$APPLESCRIPT_SRC" <<APPLESCRIPT
on run
	do shell script "nohup /bin/bash '$RUNNER' < /dev/null > '$IMMICH_DIR/launcher.log' 2>&1 & disown"
end run
APPLESCRIPT

APP_NAME="Start Immich.app"
APP_PATH="/Applications/$APP_NAME"
rm -rf "$APP_PATH"

if [[ -n "$ICON_ICNS" ]]; then
  if ! osacompile -i "$ICON_ICNS" -o "$APP_PATH" "$APPLESCRIPT_SRC" 2>/tmp/osacompile.err; then
    warn "Couldn't write to /Applications (needs admin rights) - falling back to your Desktop."
    APP_PATH="$HOME/Desktop/$APP_NAME"
    rm -rf "$APP_PATH"
    osacompile -i "$ICON_ICNS" -o "$APP_PATH" "$APPLESCRIPT_SRC"
  fi
else
  if ! osacompile -o "$APP_PATH" "$APPLESCRIPT_SRC" 2>/tmp/osacompile.err; then
    warn "Couldn't write to /Applications (needs admin rights) - falling back to your Desktop."
    APP_PATH="$HOME/Desktop/$APP_NAME"
    rm -rf "$APP_PATH"
    osacompile -o "$APP_PATH" "$APPLESCRIPT_SRC"
  fi
fi
rm -f "$APPLESCRIPT_SRC" "$ICON_ICNS"

ok "Created launcher: $APP_PATH"
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_PATH" 2>/dev/null || true
mdimport "$APP_PATH" 2>/dev/null || true
warn "This app isn't signed by an Apple developer ID. The first time you open"
warn "it, right-click it and choose 'Open' (instead of double-clicking) so"
warn "macOS lets it run - after that, double-clicking will work normally."
ok "Double-click it any time to (re)start Immich and open it in your browser."
ok "Or run it directly any time with: bash $RUNNER"
ok "If it ever fails silently, check the log at: $IMMICH_DIR/launcher.log"

header "7/8  Keep this Mac awake for Immich?"

# ---------------------------------------------------------------------------
# 7. Optionally disable sleep so Immich stays reachable 24/7
# ---------------------------------------------------------------------------
read -r -p "Prevent this Mac from sleeping so Immich stays reachable at all times? [y/N]: " NEVER_SLEEP
if [[ "$NEVER_SLEEP" =~ ^[Yy]$ ]]; then
  info "This changes a system-wide power setting and needs your admin password."
  sudo pmset -a sleep 0
  sudo pmset -a disksleep 0
  sudo pmset -a displaysleep 10   # the screen can still turn off, that's fine - the machine stays awake
  ok "Sleep disabled. The display can still turn off; the machine itself won't sleep."
  echo "   To undo this later, run:  sudo pmset -a sleep 30 disksleep 10 displaysleep 10"
else
  warn "Sleep left as-is. Note: if this Mac goes to sleep, Immich will be unreachable"
  warn "from other devices until it wakes up again."
fi

header "8/8  Done"

LOCAL_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "your-mac-ip")"
SUMMARY_LIBRARY="$(grep '^UPLOAD_LOCATION=' "$ENV_FILE" | cut -d= -f2-)"
SUMMARY_DB="$(grep '^DB_DATA_LOCATION=' "$ENV_FILE" | cut -d= -f2-)"
SUMMARY_THUMBS="$(grep '^THUMBS_LOCATION=' "$ENV_FILE" | cut -d= -f2-)"

echo "${BOLD}Immich is up.${RESET}"
echo
echo "  On this Mac:         http://localhost:2283"
echo "  From other devices:  http://$LOCAL_IP:2283   (same Wi-Fi network)"
echo
echo "  App files:            $IMMICH_DIR"
echo "  Library (photos):     $SUMMARY_LIBRARY"
echo "  Database (SSD):       $SUMMARY_DB"
echo "  Thumbnails (SSD):     $SUMMARY_THUMBS"
echo "  Launcher app:          $APP_PATH"
echo
echo "First time opening Immich, you'll create an admin account in the browser."
echo "The database password (only needed for advanced/manual DB access) is saved in:"
echo "  $IMMICH_DIR/DB_PASSWORD.txt"
