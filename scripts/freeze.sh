#!/usr/bin/env bash
#
# freeze.sh — save all tmux sessions to a frost file.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/helpers.sh"

# if "quiet" the script produces no tmux messages
SCRIPT_OUTPUT="$1"

# ── Format strings ──────────────────────────────────────────────────

pane_format() {
	local f=""
	f+="pane"
	f+="${d}#{session_name}"
	f+="${d}#{window_index}"
	f+="${d}#{window_active}"
	f+="${d}#{pane_index}"
	f+="${d}#{pane_title}"
	f+="${d}:#{pane_current_path}"
	f+="${d}#{pane_active}"
	echo "$f"
}

window_format() {
	local f=""
	f+="window"
	f+="${d}#{session_name}"
	f+="${d}#{window_index}"
	f+="${d}:#{window_name}"
	f+="${d}#{window_active}"
	f+="${d}:#{window_flags}"
	f+="${d}#{window_layout}"
	f+="${d}"
	echo "$f"
}

state_format() {
	local f=""
	f+="state"
	f+="${d}#{client_session}"
	f+="${d}#{client_last_session}"
	echo "$f"
}

# ── Layout validation (the stacked-pane fix) ────────────────────────

# Check if a window has any pane with height <= 1 (stacked).
# If so, return the "tiled" layout instead of the broken one.
validate_layout() {
	local session_name="$1"
	local window_index="$2"
	local layout_string="$3"

	local pane_count=0
	local any_tiny=false

	while IFS=$'\t' read -r height; do
		pane_count=$((pane_count + 1))
		if [ "$height" -le 1 ] 2>/dev/null; then
			any_tiny=true
		fi
	done < <(tmux list-panes -t "${session_name}:${window_index}" -F "#{pane_height}" 2>/dev/null)

	if [ "$pane_count" -gt 1 ] && [ "$any_tiny" = "true" ]; then
		echo "tiled"
	else
		echo "$layout_string"
	fi
}

# ── Dump functions ──────────────────────────────────────────────────

dump_panes() {
	tmux list-panes -a -F "$(pane_format)" | sort -t "$d" -k2,2 -k3,3n -k5,5n
}

dump_windows() {
	tmux list-windows -a -F "$(window_format)" |
		while IFS=$d read -r line_type session_name window_index window_name window_active window_flags window_layout automatic_rename; do
			# Validate layout — replace stacked layouts with "tiled"
			local safe_layout
			safe_layout="$(validate_layout "$session_name" "$window_index" "$window_layout")"

			# Fetch automatic-rename option
			automatic_rename="$(tmux show-window-options -vt "${session_name}:${window_index}" automatic-rename 2>/dev/null)"
			[ -z "$automatic_rename" ] && automatic_rename=":"

			echo "${line_type}${d}${session_name}${d}${window_index}${d}${window_name}${d}${window_active}${d}${window_flags}${d}${safe_layout}${d}${automatic_rename}"
		done
}

dump_state() {
	tmux display-message -p "$(state_format)"
}

# ── Backup retention ───────────────────────────────────────────────

remove_old_backups() {
	local delete_after
	delete_after="$(get_tmux_option "@frost-delete-backup-after" "30")"
	local dir
	dir="$(frost_dir)"

	# Collect all frost save files, sorted newest-first, skip the 5 newest
	# (mapfile is bash 4+; read into the array instead so this works on the
	# /bin/bash 3.2 that ships with macOS)
	local -a files
	local file
	while IFS= read -r file; do
		files+=("$file")
	done < <(ls -t "$dir"/frost_*.txt 2>/dev/null | tail -n +6)
	[[ ${#files[@]} -eq 0 ]] && return

	find "${files[@]}" -type f -mtime "+${delete_after}" -exec rm -f "{}" \; 2>/dev/null
}

# ── Main ───────────────────────────────────────────────────────────

save_all() {
	local frost_file
	frost_file="$(frost_file_path)"
	local last_file
	last_file="$(last_frost_file)"
	local dir
	dir="$(frost_dir)"

	mkdir -p "$dir"

	# Write version header
	echo "frost_version${d}1" > "$frost_file"

	# Dump panes, windows, state
	dump_panes   >> "$frost_file"
	dump_windows >> "$frost_file"
	dump_state   >> "$frost_file"

	# Only update the "last" symlink if the content actually changed
	if [ -f "$last_file" ] && cmp -s "$frost_file" "$(resolve_symlink "$last_file" 2>/dev/null)"; then
		rm -f "$frost_file"
	else
		ln -fs "$(basename "$frost_file")" "$last_file"
	fi

	remove_old_backups
}

main() {
	if ! acquire_lock; then
		frost_log WARN "freeze skipped — lock held by another process"
		return 0
	fi

	local mode="manual"
	[ "$SCRIPT_OUTPUT" = "quiet" ] && mode="auto"

	frost_log INFO "freeze started (${mode})"

	if [ "$SCRIPT_OUTPUT" != "quiet" ]; then
		display_message "Glacier: saving..."
	fi

	save_all

	local sessions panes
	sessions="$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')"
	panes="$(tmux list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
	frost_log INFO "freeze complete — ${sessions} sessions, ${panes} panes"

	rotate_logs

	if [ "$SCRIPT_OUTPUT" != "quiet" ]; then
		display_message "Glacier: saved!"
	fi
}
main
