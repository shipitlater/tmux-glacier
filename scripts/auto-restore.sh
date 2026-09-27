#!/usr/bin/env bash
#
# auto-restore.sh — one-shot thaw triggered by session-created hook.
#
# Restores the previous layout only if the server is fresh (≤1 pane),
# then removes the hook so it never fires again.
#

PLUGIN_DIR="$1"
source "$PLUGIN_DIR/scripts/helpers.sh"

# Remove the hook immediately so it only fires once
tmux set-hook -gu session-created

total_panes="$(tmux list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
if [ "$total_panes" -gt 1 ]; then
	frost_log INFO "auto-restore skipped — server already has $total_panes panes"
	exit 0
fi

save_file="$(last_frost_file)"
if [ ! -L "$save_file" ] && [ ! -f "$save_file" ]; then
	frost_log INFO "auto-restore skipped — no save file"
	exit 0
fi

frost_log INFO "auto-restore triggered — fresh server detected"
"$PLUGIN_DIR/scripts/thaw.sh"
