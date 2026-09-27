#!/usr/bin/env bash
#
# thaw.sh — restore tmux sessions from a frost save file.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/helpers.sh"

# ── Helpers ─────────────────────────────────────────────────────────

remove_first_char() {
	echo "$1" | cut -c2-
}

first_window_num() {
	tmux show -gv base-index
}

tmux_socket() {
	echo "$TMUX" | cut -d',' -f1
}

session_exists() {
	tmux has-session -t "$1" 2>/dev/null
}

window_exists() {
	tmux list-windows -t "$1" -F "#{window_index}" 2>/dev/null |
		\grep -q "^${2}$"
}

pane_exists() {
	tmux list-panes -t "$1:$2" -F "#{pane_index}" 2>/dev/null |
		\grep -q "^${3}$"
}

# ── Restore pane creation ──────────────────────────────────────────

new_session() {
	local session_name="$1" window_number="$2" dir="$3"
	TMUX="" tmux -S "$(tmux_socket)" new-session -d -s "$session_name" -c "$dir"
	# fix first window number if base-index differs
	local created_window_num
	created_window_num="$(first_window_num)"
	if [ "$created_window_num" -ne "$window_number" ]; then
		tmux move-window -s "${session_name}:${created_window_num}" -t "${session_name}:${window_number}"
	fi
}

new_window() {
	local session_name="$1" window_number="$2" dir="$3"
	tmux new-window -d -t "${session_name}:${window_number}" -c "$dir"
}

new_pane() {
	local session_name="$1" window_number="$2" dir="$3"
	tmux split-window -t "${session_name}:${window_number}" -c "$dir"
	# minimize so more panes can fit
	tmux resize-pane -t "${session_name}:${window_number}" -U "999"
}

# ── Core restore logic ─────────────────────────────────────────────

restore_all_panes() {
	local save_file="$1"
	local restoring_from_scratch=false
	local total_panes
	total_panes="$(tmux list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
	if [ "$total_panes" -le 1 ]; then
		restoring_from_scratch=true
	fi

	local restore_pane_title
	restore_pane_title="$(get_tmux_option "@frost-restore-pane-title" "off")"

	local restored_session_0=false
	local seen_windows=""
	local prev_session=""
	local window_preexisted=false

	# Translate tabs to \037 / US (a non-whitespace IFS char that bash 3.2
	# honours — \001 and \177 do not work as IFS there) so empty fields
	# (e.g. pane_title cleared by a TUI app) survive parsing instead of
	# collapsing and shifting every subsequent field.
	while IFS=$'\037' read -r line_type session_name window_number window_active pane_index pane_title dir pane_active; do
		[ "$line_type" = "pane" ] || continue
		dir="$(remove_first_char "$dir")"
		dir="${dir/#\~/$HOME}"
		[ "$session_name" = "0" ] && restored_session_0=true

		local window_key="${session_name}:${window_number}"

		# 2nd+ pane in this window
		if echo "$seen_windows" | grep -qF "	${window_key}	"; then
			# Reuse the pane at the saved index when the window predates
			# this thaw — splitting unconditionally would duplicate panes
			# on every re-thaw.
			if [ "$window_preexisted" = "true" ] &&
				pane_exists "$session_name" "$window_number" "$pane_index"; then
				tmux respawn-pane -k -t "${session_name}:${window_number}.${pane_index}" -c "$dir"
			else
				new_pane "$session_name" "$window_number" "$dir"
			fi
			if [ "$restore_pane_title" = "on" ] && [ -n "$pane_title" ]; then
				tmux select-pane -t "${session_name}:${window_number}" -T "$pane_title" 2>/dev/null
			fi
			continue
		fi
		seen_windows="${seen_windows}	${window_key}	"

		# First pane of a new session — check existence once
		if [ "$session_name" != "$prev_session" ]; then
			prev_session="$session_name"
			if ! session_exists "$session_name"; then
				window_preexisted=false
				new_session "$session_name" "$window_number" "$dir"
				if [ "$restore_pane_title" = "on" ] && [ -n "$pane_title" ]; then
					tmux select-pane -t "${session_name}:${window_number}" -T "$pane_title" 2>/dev/null
				fi
				continue
			fi
		fi

		# First pane of a window in an existing session
		if window_exists "$session_name" "$window_number"; then
			window_preexisted=true
			if pane_exists "$session_name" "$window_number" "$pane_index"; then
				tmux respawn-pane -k -t "${session_name}:${window_number}.${pane_index}" -c "$dir"
			else
				tmux respawn-pane -k -t "${session_name}:${window_number}" -c "$dir"
			fi
		else
			window_preexisted=false
			new_window "$session_name" "$window_number" "$dir"
		fi
		if [ "$restore_pane_title" = "on" ] && [ -n "$pane_title" ]; then
			tmux select-pane -t "${session_name}:${window_number}" -T "$pane_title" 2>/dev/null
		fi
	done < <(tr '\t' '\037' < "$save_file")

	# Clean up default session 0 if we were restoring from scratch
	if [ "$restoring_from_scratch" = "true" ] && [ "$restored_session_0" = "false" ]; then
		local current_session
		current_session="$(tmux display -p '#{client_session}' 2>/dev/null)"
		if [ "$current_session" = "0" ]; then
			tmux switch-client -n 2>/dev/null
		fi
		tmux kill-session -t "0" 2>/dev/null
	fi
}

restore_window_properties() {
	local save_file="$1"
	# shellcheck disable=SC2034  # window_flags is a positional field, not used directly
	while IFS=$d read -r line_type session_name window_number window_name window_active window_flags window_layout automatic_rename; do
		[ "$line_type" = "window" ] || continue

		# Apply layout
		tmux select-layout -t "${session_name}:${window_number}" "$window_layout" 2>/dev/null

		# Restore window name
		window_name="$(remove_first_char "$window_name")"
		tmux rename-window -t "${session_name}:${window_number}" "$window_name" 2>/dev/null

		# Restore automatic-rename
		if [ "$automatic_rename" = ":" ]; then
			tmux set-option -u -t "${session_name}:${window_number}" automatic-rename 2>/dev/null
		else
			tmux set-option -t "${session_name}:${window_number}" automatic-rename "$automatic_rename" 2>/dev/null
		fi
	done < "$save_file"
}

restore_active_panes() {
	local save_file="$1"
	while IFS=$'\037' read -r line_type session_name window_number window_active pane_index pane_title dir pane_active; do
		[ "$line_type" = "pane" ] || continue
		[ "$pane_active" = "1" ] || continue
		tmux select-pane -t "${session_name}:${window_number}.${pane_index}" 2>/dev/null
	done < <(tr '\t' '\037' < "$save_file")
}

restore_active_windows() {
	local save_file="$1"
	# shellcheck disable=SC2034  # positional fields needed to reach window_active
	while IFS=$d read -r line_type session_name window_number window_name window_active window_flags window_layout automatic_rename; do
		[ "$line_type" = "window" ] || continue
		[ "$window_active" = "1" ] || continue
		tmux select-window -t "${session_name}:${window_number}" 2>/dev/null
	done < "$save_file"
}

restore_state() {
	local save_file="$1"
	while IFS=$d read -r line_type client_session client_last_session; do
		[ "$line_type" = "state" ] || continue
		if [ -n "$client_last_session" ]; then
			tmux switch-client -t "$client_last_session" 2>/dev/null
		fi
		if [ -n "$client_session" ]; then
			tmux switch-client -t "$client_session" 2>/dev/null
		fi
	done < "$save_file"
}

# ── Main ───────────────────────────────────────────────────────────

main() {
	local save_file
	save_file="$(last_frost_file)"

	if [ ! -L "$save_file" ] && [ ! -f "$save_file" ]; then
		frost_log ERROR "thaw failed — no save file found"
		display_message "Glacier: no save file found!"
		return 1
	fi

	# Resolve the symlink to the actual file
	local actual_file
	actual_file="$(resolve_symlink "$save_file")"
	if [ ! -f "$actual_file" ]; then
		frost_log ERROR "thaw failed — save file missing: $actual_file"
		display_message "Glacier: save file missing!"
		return 1
	fi

	# Verify version header
	local first_line
	first_line="$(head -1 "$actual_file")"
	if [[ "$first_line" != frost_version* ]]; then
		frost_log ERROR "thaw failed — invalid save file: $actual_file"
		display_message "Glacier: invalid save file!"
		return 1
	fi

	if ! acquire_lock; then
		frost_log WARN "thaw skipped — lock held by another process"
		display_message "Glacier: another operation in progress"
		return 0
	fi

	frost_log INFO "thaw started from $(basename "$actual_file")"

	display_message "Glacier: restoring..."

	restore_all_panes "$actual_file"
	restore_window_properties "$actual_file"
	restore_active_panes "$actual_file"
	restore_active_windows "$actual_file"
	restore_state "$actual_file"

	local sessions panes
	sessions="$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')"
	panes="$(tmux list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
	frost_log INFO "thaw complete — ${sessions} sessions, ${panes} panes"

	display_message "Glacier: restored!"
}
main
