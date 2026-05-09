#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# install-launchagents.sh — one-time setup. Builds the server, copies the two
# plists into ~/Library/LaunchAgents/, primes the trigger file, and bootstraps
# both agents. Idempotent: bootouts existing units before re-bootstrapping, so
# safe to re-run after a plist edit.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
SERVER_DIR="$REPO_DIR/Server"
PLIST_SRC_DIR="$REPO_DIR/launchd"
PLIST_DEST_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/WorkoutChallengeServer"
TRIGGER="$REPO_DIR/.restart-trigger"
GUI_TARGET="gui/$(id -u)"

SERVER_LABEL="com.kurtpessa.workoutchallenge.server"
RESTART_LABEL="com.kurtpessa.workoutchallenge.restart"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

log "install starting (repo=$REPO_DIR)"

# --- Sanity ---------------------------------------------------------------
if ! command -v swift > /dev/null 2>&1; then
    log "FATAL: swift not on PATH. Install Xcode Command Line Tools or full Xcode."
    exit 1
fi
if [[ ! -d "$SERVER_DIR" ]]; then
    log "FATAL: $SERVER_DIR missing"
    exit 1
fi

# --- Build ---------------------------------------------------------------
log "building release binary"
if ! swift build -c release --package-path "$SERVER_DIR"; then
    log "FATAL: build failed — fix compile errors and re-run"
    exit 2
fi
BINARY="$SERVER_DIR/.build/release/Server"
[[ -x "$BINARY" ]] || { log "FATAL: build OK but binary missing at $BINARY"; exit 3; }
log "binary at $BINARY"

# --- Plists --------------------------------------------------------------
mkdir -p "$PLIST_DEST_DIR" "$LOG_DIR"
chmod +x "$SCRIPT_DIR"/*.sh

# Preserve the bearer token across re-installs. Read it out of the existing
# installed plist (if any) before we overwrite, then splice it back. Keeps the
# source plist in launchd/ free of secrets while letting you re-run install
# without re-editing the token every time.
existing_token=""
if [[ -f "$PLIST_DEST_DIR/$SERVER_LABEL.plist" ]]; then
    existing_token=$(plutil -extract EnvironmentVariables.WORKOUT_CHALLENGE_TOKEN raw \
        "$PLIST_DEST_DIR/$SERVER_LABEL.plist" 2> /dev/null || true)
fi

log "copying plists to $PLIST_DEST_DIR"
install -m 644 "$PLIST_SRC_DIR/$SERVER_LABEL.plist"  "$PLIST_DEST_DIR/$SERVER_LABEL.plist"
install -m 644 "$PLIST_SRC_DIR/$RESTART_LABEL.plist" "$PLIST_DEST_DIR/$RESTART_LABEL.plist"

if [[ -n "$existing_token" && "$existing_token" != "REPLACE_ME_WITH_BEARER_TOKEN" ]]; then
    plutil -replace EnvironmentVariables.WORKOUT_CHALLENGE_TOKEN -string "$existing_token" \
        "$PLIST_DEST_DIR/$SERVER_LABEL.plist"
    log "preserved existing WORKOUT_CHALLENGE_TOKEN from previous install"
fi

# --- Trigger file ---------------------------------------------------------
# Must exist before bootstrap or WatchPaths has nothing to watch and the
# restart agent silently no-ops.
if [[ ! -f "$TRIGGER" ]]; then
    log "creating $TRIGGER"
    : > "$TRIGGER"
fi

# --- Bootstrap (idempotent) ----------------------------------------------
for label in "$SERVER_LABEL" "$RESTART_LABEL"; do
    if launchctl print "$GUI_TARGET/$label" > /dev/null 2>&1; then
        log "bootout existing $label"
        launchctl bootout "$GUI_TARGET/$label" || true
    fi
    log "bootstrap $label"
    launchctl bootstrap "$GUI_TARGET" "$PLIST_DEST_DIR/$label.plist"
done

# --- Sanity check the bind ------------------------------------------------
sleep 1
if curl -sf http://localhost:9080/healthz > /dev/null; then
    log "healthz OK — server is up on :9080"
else
    log "WARNING: /healthz didn't respond yet. Check $LOG_DIR/err.log"
fi

cat <<EOF

==============================================================================
  install complete

  Service:  $SERVER_LABEL
  Binary:   $BINARY
  Logs:     $LOG_DIR/{out,err,restart}.log
  Trigger:  touch $TRIGGER   # rebuild + bounce from anywhere

  IMPORTANT — token:
    Edit $PLIST_DEST_DIR/$SERVER_LABEL.plist
    and replace WORKOUT_CHALLENGE_TOKEN's value, then re-run this script.
    (The token must match what the iOS app sends in Authorization: Bearer.)

  TCC grants (only needed once a writer touches a protected path):
    System Settings → Privacy & Security → Full Disk Access
      add: $BINARY
    Required because the server writes into ~/code/llm-vault, which is
    fine today, but if you ever point LLM_VAULT_PATH at a Documents/Desktop
    subdir or anywhere TCC-guarded, this is where the EPERM error comes from.

  Tailscale:
    Confirm the Mac mini is reachable from your iPhone over the tailnet at
    http://<mac-mini-tailscale-name>:9080/healthz
==============================================================================
EOF
