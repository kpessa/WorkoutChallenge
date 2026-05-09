#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# restart.sh — rebuild the Server target and kickstart the running LaunchAgent.
#
# Triggered by `touch .restart-trigger` from anywhere (terminal, editor save
# hook, Claude session). Bails before kickstart if the build fails — better to
# keep the old binary serving than to bounce into a crashloop.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"
SERVER_DIR="$REPO_DIR/Server"
SERVICE_LABEL="com.kurtpessa.workoutchallenge.server"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

log "restart triggered (repo=$REPO_DIR)"
cd "$REPO_DIR"

if [[ ! -d "$SERVER_DIR" ]]; then
    log "FATAL: Server/ directory not found at $SERVER_DIR"
    exit 1
fi

# --- Build ---------------------------------------------------------------
log "swift build -c release --package-path Server"
if ! swift build -c release --package-path Server; then
    log "BUILD FAILED — keeping currently running binary, NOT kickstarting"
    exit 2
fi

BINARY="$SERVER_DIR/.build/release/Server"
if [[ ! -x "$BINARY" ]]; then
    log "FATAL: build succeeded but binary missing at $BINARY"
    exit 3
fi
log "build OK, binary at $BINARY"

# --- Kickstart -----------------------------------------------------------
GUI_TARGET="gui/$(id -u)/$SERVICE_LABEL"
log "launchctl kickstart -k $GUI_TARGET"
if launchctl kickstart -k "$GUI_TARGET"; then
    log "kickstart OK"
else
    rc=$?
    log "kickstart returned $rc — service may not be loaded yet. Run install-launchagents.sh."
    exit $rc
fi

log "restart complete"
