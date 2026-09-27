#!/usr/bin/env bash
#
# auto_save_loop.sh — daemonised auto-save loop for tmux-glacier.
#
# Fully detaches from the calling process so tmux run-shell (and TPM)
# can return immediately.

# Arguments: $1: pid_file (unused, written by parent), $2: interval, $3: freeze_script, $4: tmux_socket
interval="$2"
freeze_script="$3"
tmux_socket="$4"

# Close every inherited fd beyond stderr so the tmux run-shell pipe
# reaches EOF and the caller is unblocked.
if [ -d "/proc/$$/fd" ]; then
	for fd in /proc/$$/fd/*; do
		n="$(basename "$fd")"
		(( n > 2 )) && eval "exec $n>&-" 2>/dev/null
	done
else
	# macOS 등 /proc이 없는 환경을 위해 고정 범위 3-255 파일 디스크립터를 닫음
	for n in {3..255}; do
		eval "exec $n>&-" 2>/dev/null
	done
fi
exec </dev/null >/dev/null 2>&1

while true; do
	sleep "$interval"
	# Use explicit socket so we don't depend on TMUX env var
	tmux -S "$tmux_socket" run-shell "'$freeze_script' quiet"
done
