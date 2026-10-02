#!/usr/bin/env bash
#
# thaw-key.sh — restore-key entry point with optional confirm-before.
#
# Decides at keypress time whether to prompt based on @frost-thaw-confirm
# and server-wide session pane counts. Auto-restore calls thaw.sh directly
# and never goes through this script.
#
# confirm-before invoked from inside run-shell does not wait for a key in
# this process. Its exit status is not the user's answer (an invalid command
# such as ':' fails immediately and never shows the prompt). Schedule the
# prompt in the client and let tmux run thaw only when the user answers y.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$CURRENT_DIR/helpers.sh"

thaw_script="$CURRENT_DIR/thaw.sh"

if frost_thaw_needs_confirm; then
	# One status-line prompt for the whole thaw. Only 'y' runs the command.
	# Do not branch on this exit code: from run-shell it is not a decline.
	tmux confirm-before -p 'Glacier: restore sessions from last save? (y/n)' \
		"run-shell '$thaw_script'"
	exit 0
fi
exec "$thaw_script"
