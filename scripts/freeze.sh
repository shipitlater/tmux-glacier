#!/usr/bin/env bash
#
# freeze.sh — save all tmux sessions to a frost_* save file.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/helpers.sh"
# shellcheck source=scripts/user_options.sh
source "$CURRENT_DIR/user_options.sh"

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

dump_panes() (
	set -o pipefail
	tmux list-panes -a -F "$(pane_format)" | sort -t "$d" -k2,2 -k3,3n -k5,5n
)

dump_pane_user_options() {
	local LC_ALL=C
	local panes pane_id session_name window_index pane_index
	local names encoded_name name value encoded_value
	panes="$(set -o pipefail; tmux -u list-panes -a -F "#{session_name}${d}#{window_index}${d}#{pane_index}${d}#{pane_id}" | sort -t "$d" -k1,1 -k2,2n -k3,3n)" || return 1
	[ -n "$panes" ] || return 0

	while IFS="$d" read -r session_name window_index pane_index pane_id || [ -n "$session_name$window_index$pane_index$pane_id" ]; do
		# Skip blank lines from list input; non-empty incomplete rows still fail.
		if [ -z "$session_name$window_index$pane_index$pane_id" ]; then
			continue
		fi
		[ -n "$pane_id" ] || return 1
		names="$(list_pane_user_option_names "$pane_id")" || return 1
		printf 'pane_user_options%s%s%s%s%s%s\n' "$d" "$session_name" "$d" "$window_index" "$d" "$pane_index" || return 1
		[ -n "$names" ] || continue
		while IFS= read -r encoded_name || [ -n "$encoded_name" ]; do
			[ -n "$encoded_name" ] || continue
			decode_option_field "$encoded_name" name || return 1
			capture_option_value "$pane_id" "$name" value || return 1
			encoded_value="$(printf '%s' "$value" | encode_base64)" || return 1
			printf 'pane_user_option%s%s%s%s%s%s%s%s%sb64:%s\n' "$d" "$session_name" "$d" "$window_index" "$d" "$pane_index" "$d" "$encoded_name" "$d" "$encoded_value" || return 1
		done <<< "$names"
	done <<< "$panes"
}

# Save all directly set @* user options without interpreting their names.
dump_window_user_options() {
	local LC_ALL=C
	local windows window_id session_name window_index
	local names encoded_name name value encoded_value
	windows="$(set -o pipefail; tmux -u list-windows -a -F "#{session_name}${d}#{window_index}${d}#{window_id}" 2>/dev/null | sort -t "$d" -k1,1 -k2,2n)" || return 1
	[ -n "$windows" ] || return 0

	while IFS="$d" read -r session_name window_index window_id || [ -n "$session_name$window_index$window_id" ]; do
		if [ -z "$session_name$window_index$window_id" ]; then
			continue
		fi
		[ -n "$window_id" ] || return 1
		names="$(list_window_user_option_names "$window_id")" || return 1
		printf 'window_user_options%s%s%s%s\n' "$d" "$session_name" "$d" "$window_index" || return 1
		[ -n "$names" ] || continue
		while IFS= read -r encoded_name || [ -n "$encoded_name" ]; do
			[ -n "$encoded_name" ] || continue
			decode_option_field "$encoded_name" name || return 1
			capture_option_value "$window_id" "$name" value w || return 1
			encoded_value="$(printf '%s' "$value" | encode_base64)" || return 1
			printf 'window_user_option%s%s%s%s%s%s%sb64:%s\n' "$d" "$session_name" "$d" "$window_index" "$d" "$encoded_name" "$d" "$encoded_value" || return 1
		done <<< "$names"
	done <<< "$windows"
}

dump_windows() (
	set -o pipefail
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
)

dump_state() {
	tmux display-message -p "$(state_format)"
}

# ── Backup retention ───────────────────────────────────────────────

remove_old_backups() {
	local delete_after
	delete_after="$(get_tmux_option "@frost-delete-backup-after" "30")"
	local dir
	dir="$(frost_dir)" || return 1

	# Collect all frost save files, sorted newest-first, skip the 5 newest
	# (mapfile is bash 4+; read into the array instead so this works on the
	# /bin/bash 3.2 that ships with macOS)
	local -a files
	local file
	local last_file="$dir/last"
	while IFS= read -r file; do
		# Preserve the file selected by last, including old saves imported by migration.
		[ "$file" -ef "$last_file" ] && continue
		files+=("$file")
	done < <(ls -t "$dir"/frost_*.txt 2>/dev/null | tail -n +6)
	[[ ${#files[@]} -eq 0 ]] && return

	find "${files[@]}" -type f -mtime "+${delete_after}" -exec rm -f "{}" \; 2>/dev/null
}

# ── Main ───────────────────────────────────────────────────────────

save_all() {
	local frost_file last_file dir temporary_file temporary_link base sequence
	frost_file="$(frost_file_path)" || return 1
	last_file="$(last_frost_file)" || return 1
	dir="$(frost_dir)" || return 1
	mkdir -p "$dir" || return 1
	temporary_file="$(mktemp "$dir/.frost-save.XXXXXX")" || return 1

	# Bash 3.2 does not invert a compound command's redirection failure with !.
	if {
		printf 'frost_version%s3\n' "$d" &&
		dump_panes &&
		dump_pane_user_options &&
		dump_window_user_options &&
		dump_windows &&
		dump_state
	} > "$temporary_file"; then
		:
	else
		rm -f "$temporary_file"
		return 1
	fi

	if [ -f "$last_file" ] && cmp -s "$temporary_file" "$last_file"; then
		rm -f "$temporary_file" || return 1
		remove_old_backups
		return $?
	fi

	if [ -e "$frost_file" ] || [ -L "$frost_file" ]; then
		base="${frost_file%.txt}"
		sequence=1
		while [ -e "${base}_${sequence}.txt" ] || [ -L "${base}_${sequence}.txt" ]; do
			sequence=$((sequence + 1))
		done
		frost_file="${base}_${sequence}.txt"
	fi
	if ! mv "$temporary_file" "$frost_file"; then
		rm -f "$temporary_file"
		return 1
	fi

	temporary_link="$(mktemp "$dir/.frost-last.XXXXXX")" || {
		rm -f "$frost_file"
		return 1
	}
	if ! rm -f "$temporary_link" || ! ln -s "$(basename "$frost_file")" "$temporary_link" || ! mv -f "$temporary_link" "$last_file"; then
		rm -f "$temporary_link" "$frost_file"
		return 1
	fi

	remove_old_backups
}

main() {
	local lock_status=0
	acquire_lock || lock_status=$?
	if [ "$lock_status" -eq 1 ]; then
		frost_log WARN "freeze skipped — lock held by another process"
		return 0
	elif [ "$lock_status" -ne 0 ]; then
		frost_log ERROR "Glacier: failed to prepare save directory or lock file"
		return 1
	fi

	local mode="manual"
	[ "$SCRIPT_OUTPUT" = "quiet" ] && mode="auto"

	frost_log INFO "freeze started (${mode})"

	if [ "$SCRIPT_OUTPUT" != "quiet" ]; then
		display_message "Glacier: saving..."
	fi

	if ! save_all; then
		frost_log ERROR "Freeze save failed"
		return 1
	fi

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
