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
	tmux bind-key "$key" run-shell "'$CURRENT_DIR/scripts/thaw.sh'"
}

# ── Auto-save ───────────────────────────────────────────────────────

# Background loop that saves at a fixed interval.
# The loop is a child of the tmux server, so it dies on normal exit.
# A PID file prevents duplicates on config reloads.

stop_auto_save() {
	local dir
	dir="$(frost_dir)"
	local pid_file="$dir/.auto_save.pid"

	if [ -f "$pid_file" ]; then
		local old_pid
		old_pid="$(cat "$pid_file")"
		if kill -0 "$old_pid" 2>/dev/null; then
			kill "$old_pid" 2>/dev/null
		fi
		rm -f "$pid_file"
	fi
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
	dir="$(frost_dir)"
	local pid_file="$dir/.auto_save.pid"
	local freeze_script="$CURRENT_DIR/scripts/freeze.sh"

	mkdir -p "$dir"

	# If a loop is already running, leave it alone.
	# Verify the PID is actually our loop, not a recycled PID.
	if [ -f "$pid_file" ]; then
		local old_pid
		old_pid="$(cat "$pid_file")"
		if kill -0 "$old_pid" 2>/dev/null &&
			ps -p "$old_pid" -o args= 2>/dev/null | grep -q "auto_save_loop"; then
			frost_log INFO "auto-save loop already running (pid $old_pid)"
			return
		fi
		rm -f "$pid_file"
	fi

	# Extract the socket path from $TMUX (format: /path/to/socket,pid,session)
	local tmux_socket
	tmux_socket="$(echo "$TMUX" | cut -d, -f1)"

	# Launch via setsid into a dedicated script that closes all inherited
	# fds — this prevents tmux's run-shell pipe from staying open, which
	# would block TPM installs and config reloads.
	if command -v setsid >/dev/null 2>&1; then
		setsid "$CURRENT_DIR/scripts/auto_save_loop.sh" \
			"$pid_file" "$((interval * 60))" "$freeze_script" "$tmux_socket" &
	else
		# setsid가 없는 macOS 등에서는 nohup을 사용하여 백그라운드 분리 기동
		nohup "$CURRENT_DIR/scripts/auto_save_loop.sh" \
			"$pid_file" "$((interval * 60))" "$freeze_script" "$tmux_socket" >/dev/null 2>&1 &
	fi
	# 자식 프로세스 기동 즉시 부모 쉘이 PID를 파일에 기록하여 Race Condition 방지
	echo $! > "$pid_file"
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
