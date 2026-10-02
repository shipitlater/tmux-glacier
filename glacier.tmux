#!/usr/bin/env bash
#
# glacier.tmux — TPM entry point for tmux-glacier.
#
# Minimal session save/restore with built-in auto-save.
# Fixes the stacked-pane bug by validating layouts at save time.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/scripts/helpers.sh"

# ── Keybindings ─────────────────────────────────────────────────────

set_freeze_binding() {
	local key
	key="$(get_tmux_option "@frost-save-key" "C-s")"
	tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/freeze.sh"
}

set_thaw_binding() {
	local key
	key="$(get_tmux_option "@frost-restore-key" "C-r")"
	# thaw-key.sh reads @frost-thaw-confirm and session pane counts at keypress time.
	tmux bind-key "$key" run-shell "'$CURRENT_DIR/scripts/thaw-key.sh'"
}

# ── Auto-save ───────────────────────────────────────────────────────

# Background loop that saves at a fixed interval.
# The loop monitors the original tmux server PID and exits when the server stops.
# A PID file prevents duplicates on config reloads.

stop_auto_save() {
	local dir
	dir="$(frost_dir)" || return 1
	local pid_file="$dir/.auto_save.pid"
	local meta_file="$dir/.auto_save.meta"

	if [ -f "$pid_file" ]; then
		local old_pid retries=0
		old_pid="$(cat "$pid_file")"
		if kill -0 "$old_pid" 2>/dev/null; then
			kill "$old_pid" 2>/dev/null || true
			# Wait for EXIT cleanup before a new loop uses the same files.
			while kill -0 "$old_pid" 2>/dev/null; do
				if [ "$retries" -ge 30 ]; then
					frost_log ERROR "failed to stop existing auto-save loop (pid $old_pid)"
					return 1
				fi
				sleep 0.1
				retries=$((retries + 1))
			done
		fi
	fi
	rm -f "$pid_file" "$meta_file"
}

setup_auto_save() {
	local interval
	interval="$(get_tmux_option "@frost-auto-save-interval" "15")"

	# 0 means disabled
	if [ "$interval" = "0" ]; then
		stop_auto_save
		return
	fi

	local dir
	dir="$(frost_dir)" || return 1
	local pid_file="$dir/.auto_save.pid"
	local meta_file="$dir/.auto_save.meta"
	local loop_script="$CURRENT_DIR/scripts/auto_save_loop.sh"
	local freeze_script="$CURRENT_DIR/scripts/freeze.sh"

	mkdir -p "$dir" || return 1

	local tmux_socket tmux_server_pid
	tmux_socket="$(echo "$TMUX" | cut -d, -f1)"
	tmux_server_pid="$(tmux -S "$tmux_socket" display-message -p '#{pid}')" || return 1

	# Reuse a loop only if its server, script paths, and fingerprints match.
	# Restart with the current scripts after a server restart, plugin move, or update.
	if [ -f "$pid_file" ]; then
		local old_pid old_args
		old_pid="$(cat "$pid_file")"
		old_args="$(ps -ww -p "$old_pid" -o args= 2>/dev/null)"
		if kill -0 "$old_pid" 2>/dev/null &&
			printf '%s\n' "$old_args" | grep -q "auto_save_loop"; then
			# The final argument is the original server PID, identifying restarts on the same socket.
			if auto_save_meta_matches "$meta_file" "$loop_script" "$freeze_script" &&
				[ "${old_args##* }" = "$tmux_server_pid" ]; then
				frost_log INFO "auto-save loop already running (pid $old_pid)"
				return
			fi
			frost_log INFO "restarting auto-save loop after script or server change (previous pid $old_pid)"
			stop_auto_save || return 1
		else
			rm -f "$pid_file" "$meta_file"
		fi
	fi

	# Launch via setsid into a dedicated script that closes all inherited
	# fds — this prevents tmux's run-shell pipe from staying open, which
	# would block TPM installs and config reloads.
	if command -v setsid >/dev/null 2>&1; then
		setsid "$loop_script" \
			"$pid_file" "$((interval * 60))" "$freeze_script" "$tmux_socket" "$tmux_server_pid" &
	else
		# On macOS and other systems without setsid, use nohup to launch detached in the background.
		nohup "$loop_script" \
			"$pid_file" "$((interval * 60))" "$freeze_script" "$tmux_socket" "$tmux_server_pid" >/dev/null 2>&1 &
	fi
	# Record the new loop's PID immediately and stop it if writing its files fails.
	local new_pid=$!
	if ! printf '%s\n' "$new_pid" > "$pid_file" || ! write_auto_save_meta "$meta_file" "$loop_script" "$freeze_script"; then
		kill "$new_pid" 2>/dev/null
		rm -f "$pid_file" "$meta_file"
		return 1
	fi
	frost_log INFO "auto-save loop started (interval ${interval}m)"
}

# ── Auto-restore ───────────────────────────────────────────────────

# Register a one-shot session-created hook that restores on first
# session, then removes itself.  This defers thaw until tmux is
# fully initialised and ready to create sessions/windows/panes.

setup_auto_restore() {
	local enabled
	enabled="$(get_tmux_option "@frost-auto-restore" "on")"
	[ "$enabled" = "on" ] || return

	tmux set-hook -g session-created \
		"run-shell '\"$CURRENT_DIR/scripts/auto-restore.sh\" \"$CURRENT_DIR\"'"
}

# ── Main ───────────────────────────────────────────────────────────

main() {
	frost_log INFO "plugin loaded"
	set_freeze_binding
	set_thaw_binding
	setup_auto_restore
	setup_auto_save
}
main
