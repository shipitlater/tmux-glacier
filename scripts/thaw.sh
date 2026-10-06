#!/usr/bin/env bash
#
# thaw.sh — restore tmux sessions from a frost_* save file.
#

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/helpers.sh"
# shellcheck source=scripts/user_options.sh
source "$CURRENT_DIR/user_options.sh"

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

restore_pane_user_options() {
	restore_user_options "$1" pane p
}

restore_window_user_options() {
	restore_user_options "$1" window w
}

# Validate every record before replacing local @* user options for each exact target.
restore_user_options() {
	local save_file="$1" scope="$2" option_scope="$3" line remainder line_type key target target_id inventory
	local marker_fields option_fields inventory_format inventory_command
	local name value names encoded_name escaped_target escaped_name escaped_value
	local i j count field_count line_number=0 result=0 valid
	local current_session current_window current_pane current_id
	local -a fields keys markers corrupt owners saved_names saved_values current_names
	keys=() markers=() corrupt=() owners=() saved_names=() saved_values=()
	if [ "$scope" = pane ]; then
		marker_fields=4 option_fields=6 inventory_command=list-panes
		inventory_format="#{session_name}${d}#{window_index}${d}#{pane_index}${d}#{pane_id}"
	else
		marker_fields=3 option_fields=5 inventory_command=list-windows
		inventory_format="#{session_name}${d}#{window_index}${d}#{window_id}"
	fi

	while IFS= read -r line || [ -n "$line" ]; do
		line_number=$((line_number + 1))
		line_type="${line%%$'\t'*}"
		case "$line_type" in "${scope}_user_options"|"${scope}_user_option") ;; *) continue ;; esac

		# Split only on actual tabs, without IFS whitespace collapsing or replacing with another delimiter.
		fields=()
		remainder="$line"
		while [[ "$remainder" == *$'\t'* ]]; do
			fields[${#fields[@]}]="${remainder%%$'\t'*}"
			remainder="${remainder#*$'\t'}"
		done
		fields[${#fields[@]}]="$remainder"
		field_count=${#fields[@]}
		valid=true
		[ -n "${fields[1]:-}" ] || valid=false
		case "${fields[2]:-}" in ''|*[!0-9]*) valid=false ;; esac
		if [ "$scope" = pane ]; then
			case "${fields[3]:-}" in ''|*[!0-9]*) valid=false ;; esac
		fi
		if [ "$valid" = false ]; then
			frost_log ERROR "${scope} user option restore: invalid identifier at line ${line_number}"
			result=1
			continue
		fi
		if [ "$line_type" = "${scope}_user_options" ] && [ "$field_count" -ne "$marker_fields" ]; then
			frost_log ERROR "${scope} user option restore: marker validation failed at line ${line_number}"
			result=1
			continue
		fi

		key="${fields[1]}${d}${fields[2]}"
		target="${fields[1]}:${fields[2]}"
		if [ "$scope" = pane ]; then
			key="${key}${d}${fields[3]}"
			target="${target}.${fields[3]}"
		fi
		count=${#keys[@]}
		for ((i = 0; i < count; i++)); do
			[ "${keys[i]}" = "$key" ] && break
		done
		if [ "$i" -eq "$count" ]; then
			keys[i]="$key" markers[i]=false corrupt[i]=false
		fi
		if [ "$line_type" = "${scope}_user_options" ]; then
			markers[i]=true
		elif [ "$line_type" = "${scope}_user_option" ] && [ "$field_count" -eq "$option_fields" ] &&
			decode_option_field "${fields[marker_fields]}" name && [[ "$name" == @* ]] &&
			decode_option_field "${fields[marker_fields+1]}" value; then
			j=${#owners[@]}
			owners[j]="$i" saved_names[j]="$name" saved_values[j]="$value"
		else
			corrupt[i]=true
			result=1
			frost_log ERROR "${scope} user option restore: ${target} record validation failed (line ${line_number})"
		fi
	done < "$save_file"

	[ "${#keys[@]}" -gt 0 ] || return "$result"
	# Avoid tmux prefix and current-target resolution; use only an exact path match.
	if ! inventory="$(tmux -u "$inventory_command" -a -F "$inventory_format" 2>/dev/null)"; then
		frost_log ERROR "${scope} user option restore: failed to list target ${scope}s"
		return 1
	fi
	for ((i = 0; i < ${#keys[@]}; i++)); do
		IFS=$'\t' read -r current_session current_window current_pane <<<"${keys[i]}"
		target="${current_session}:${current_window}"
		[ "$scope" != pane ] || target="${target}.${current_pane}"
		if [ "${markers[i]}" = false ]; then
			frost_log WARN "${scope} user option restore: ignoring ${target} record without a valid marker"
			result=1
			continue
		fi
		[ "${corrupt[i]}" = false ] || continue
		target_id=''
		while IFS=$'\t' read -r current_session current_window current_pane current_id; do
			key="${current_session}${d}${current_window}"
			if [ "$scope" = pane ]; then
				key="${key}${d}${current_pane}"
			else
				current_id="$current_pane"
			fi
			if [ "$key" = "${keys[i]}" ]; then
				target_id="$current_id"
				break
			fi
		done <<<"$inventory"
		if [ -z "$target_id" ]; then
			frost_log WARN "${scope} user option restore: no target ${scope} for ${target} (orphan thaw)"
			continue
		fi
		if ! names="$(list_user_option_names "$target_id" "$option_scope" 2>/dev/null)"; then
			frost_log ERROR "${scope} user option restore: failed to list local names for ${target}"
			result=1
			continue
		fi
		current_names=()
		valid=true
		while IFS= read -r encoded_name; do
			[ -n "$encoded_name" ] || continue
			if ! decode_option_field "$encoded_name" name; then
				valid=false
				break
			fi
			current_names[${#current_names[@]}]="$name"
		done <<<"$names"
		if [ "$valid" = false ]; then
			frost_log ERROR "${scope} user option restore: failed to decode local names for ${target}"
			result=1
			continue
		fi

		escape_tmux_argument "$target_id" escaped_target
		for name in "${current_names[@]}"; do
			prepare_tmux_option_name "$name" escaped_name
			if ! tmux -u set-option "-u${option_scope}" -t "$escaped_target" "$escaped_name" 2>/dev/null; then
				frost_log ERROR "${scope} user option restore: failed to delete local options for ${target}"
				result=1
				valid=false
				break
			fi
		done
		[ "$valid" = true ] || continue
		for ((j = 0; j < ${#owners[@]}; j++)); do
			[ "${owners[j]}" = "$i" ] || continue
			prepare_tmux_option_name "${saved_names[j]}" escaped_name
			escape_tmux_argument "${saved_values[j]}" escaped_value
			if ! tmux -u set-option "-${option_scope}" -t "$escaped_target" "$escaped_name" "$escaped_value" 2>/dev/null; then
				frost_log ERROR "${scope} user option restore: failed to set saved options for ${target}"
				result=1
			fi
		done
	done
	return "$result"
}

restore_window_properties() {
	local save_file="$1"
	# shellcheck disable=SC2034  # window_flags is a positional field, not used directly
	while IFS=$d read -r line_type session_name window_number window_name window_active window_flags window_layout automatic_rename; do
		[ "$line_type" = "window" ] || continue

		# Apply layout
		tmux select-layout -t "${session_name}:${window_number}" "$window_layout" 2>/dev/null

		# Restore tmux's built-in window name.
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
	save_file="$(last_frost_file)" || return 1

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

	# Verify the version before changing tmux state.
	local first_line version_field version_value
	first_line="$(head -1 "$actual_file")"
	IFS=$'\t' read -r version_field version_value _ <<<"$first_line"
	if [ "$version_field" != "frost_version" ] || { [ "$version_value" != "1" ] && [ "$version_value" != "2" ] && [ "$version_value" != "3" ]; }; then
		frost_log ERROR "thaw failed — unsupported frost_version: ${version_value:-missing} ($actual_file)"
		display_message "Glacier: unsupported save version!"
		return 1
	fi

	local lock_status=0
	acquire_lock || lock_status=$?
	if [ "$lock_status" -eq 1 ]; then
		frost_log WARN "thaw skipped — lock held by another process"
		display_message "Glacier: another operation in progress"
		return 0
	elif [ "$lock_status" -ne 0 ]; then
		frost_log ERROR "Glacier: failed to prepare save directory or lock file"
		return 1
	fi

	frost_log INFO "thaw started from $(basename "$actual_file")"

	display_message "Glacier: restoring..."

	local option_status=0
	restore_all_panes "$actual_file"
	restore_window_user_options "$actual_file" || option_status=1
	restore_pane_user_options "$actual_file" || option_status=1
	restore_window_properties "$actual_file"
	restore_active_panes "$actual_file"
	restore_active_windows "$actual_file"
	restore_state "$actual_file"

	if [ "$option_status" -ne 0 ]; then
		frost_log ERROR 'partial thaw restore: failed to restore some window or pane user options'
		display_message 'Glacier: some window or pane user options could not be restored; check the logs'
		return 1
	fi

	local sessions panes
	sessions="$(tmux list-sessions 2>/dev/null | wc -l | tr -d ' ')"
	panes="$(tmux list-panes -a 2>/dev/null | wc -l | tr -d ' ')"
	frost_log INFO "thaw complete — ${sessions} sessions, ${panes} panes"

	display_message "Glacier: restored!"
}
main
