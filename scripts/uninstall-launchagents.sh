#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# uninstall-launchagents.sh — bootout both agents and remove the installed
# plists from ~/Library/LaunchAgents/. Leaves logs and the .build directory
# alone (delete those manually if you want a fully clean slate).
# -----------------------------------------------------------------------------
set -euo pipefail

PLIST_DEST_DIR="$HOME/Library/LaunchAgents"
GUI_TARGET="gui/$(id -u)"

SERVER_LABEL="com.kurtpessa.workoutchallenge.server"
RESTART_LABEL="com.kurtpessa.workoutchallenge.restart"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

for label in "$SERVER_LABEL" "$RESTART_LABEL"; do
    if launchctl print "$GUI_TARGET/$label" > /dev/null 2>&1; then
        log "bootout $label"
        launchctl bootout "$GUI_TARGET/$label" || true
    else
        log "$label not loaded, skipping bootout"
    fi
    if [[ -f "$PLIST_DEST_DIR/$label.plist" ]]; then
        log "rm $PLIST_DEST_DIR/$label.plist"
        rm -f "$PLIST_DEST_DIR/$label.plist"
    fi
done

log "uninstall complete (logs and build artifacts left in place)"
