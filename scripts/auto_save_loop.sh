#!/usr/bin/env bash
#
# auto_save_loop.sh — daemonised auto-save loop for tmux-glacier.
#
# Fully detaches from the calling process so tmux run-shell (and TPM)
# can return immediately.

# Arguments: $1 PID file, $2 interval (seconds), $3 freeze script, $4 socket, $5 server PID.
pid_file="$1"
interval="$2"
freeze_script="$3"
tmux_socket="$4"
server_pid="$5"

# Close every inherited fd beyond stderr so the tmux run-shell pipe
# reaches EOF and the caller is unblocked.
if [ -d "/proc/$$/fd" ]; then
	for fd in /proc/$$/fd/*; do
		n="$(basename "$fd")"
		(( n > 2 )) && eval "exec $n>&-" 2>/dev/null
	done
else
	# Close file descriptors in the fixed range 3-255 for environments without /proc, such as macOS.
	for n in {3..255}; do
		eval "exec $n>&-" 2>/dev/null
	done
fi
exec </dev/null >/dev/null 2>&1

cleanup_auto_save() {
	if [ -n "${sleep_pid:-}" ]; then
		kill "$sleep_pid" 2>/dev/null || true
		wait "$sleep_pid" 2>/dev/null || true
	fi
	# Check ownership so an exiting loop does not delete its successor's files.
	if [ "$(cat "$pid_file" 2>/dev/null)" = "$$" ]; then
		rm -f "$pid_file" "${pid_file%.pid}.meta"
	fi
}
trap cleanup_auto_save EXIT
trap 'exit 0' INT TERM

remaining="$interval"
while kill -0 "$server_pid" 2>/dev/null; do
	# Check for server exit every second, even with a long save interval.
	# Use wait so the TERM trap runs promptly during a restart instead of waiting for sleep.
	sleep 1 &
	sleep_pid=$!
	wait "$sleep_pid"
	sleep_pid=''
	kill -0 "$server_pid" 2>/dev/null || break
	remaining=$((remaining - 1))
	[ "$remaining" -le 0 ] || continue
	# Use explicit socket so we don't depend on TMUX env var
	tmux -S "$tmux_socket" run-shell "'$freeze_script' quiet" || break
	remaining="$interval"
done
