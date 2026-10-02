#!/usr/bin/env bash

# tmux-glacier helpers — shared utilities for freeze and thaw

# shellcheck disable=SC2034  # used by sourcing scripts (freeze.sh, thaw.sh)
d=$'\t'

default_frost_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/glacier"
default_frost_cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux/glacier"
_frost_dir_cache=""
_frost_dir_cache_key=""

# Read a tmux user option with a default fallback.
get_tmux_option() {
  local option="$1"
  local default_value="$2"
  local option_value
  option_value="$(tmux show-option -gqv "$option")"
  if [ -z "$option_value" ]; then
    echo "$default_value"
  else
    echo "$option_value"
  fi
}

# Expand ~ and $HOME in a configured path without resolving symlinks yet.
expand_frost_dir_setting() {
  local path="$1"
  printf '%s' "$path" | sed "s,\$HOME,$HOME,g; s,\~,$HOME,g"
}

# Reject empty, non-absolute, root, and newline-bearing @frost-dir values.
validate_frost_dir_setting() {
  local path="$1"
  if [ -z "$path" ]; then
    echo "Glacier: @frost-dir is empty" >&2
    return 1
  fi
  case "$path" in
    *$'\n'*|*$'\r'*)
      echo "Glacier: @frost-dir contains a newline" >&2
      return 1
      ;;
    /)
      echo "Glacier: @frost-dir must not be the filesystem root" >&2
      return 1
      ;;
    /*) ;;
    *)
      echo "Glacier: @frost-dir must expand to an absolute path" >&2
      return 1
      ;;
  esac
  return 0
}

# True when the directory can be created and receives a probe file.
frost_dir_is_writable() {
  local dir="$1"
  local probe
  mkdir -p "$dir" 2>/dev/null || return 1
  probe="$(mktemp "$dir/.frost-write.XXXXXX" 2>/dev/null)" || return 1
  rm -f "$probe"
  return 0
}

# Copy snapshots for each source path and link to the save selected by the source's last.
migrate_frost_dir_once() {
  local src="$1"
  local dest="$2"
  local marker="$dest/.frost-migrated-from"
  local file base target sequence source_last last_target='' temporary_link

  mkdir -p "$dest" || return 1
  if [ -f "$marker" ] && [ "$(cat "$marker")" = "$src" ]; then
    return 0
  fi

  if [ -L "$src/last" ] && [ ! -f "$src/last" ]; then
    return 1
  fi

  for file in "$src"/frost_*.txt "$src/last"; do
    [ -f "$file" ] || continue
    if [ "$file" = "$src/last" ]; then
      source_last="$(resolve_symlink "$file")" || return 1
      base="$(basename "$source_last")"
      [ "$base" != last ] || base=frost_migrated.txt
    else
      base="$(basename "$file")"
    fi
    target="$dest/$base"
    sequence=0
    while [ -e "$target" ] || [ -L "$target" ]; do
      cmp -s "$file" "$target" && break
      sequence=$((sequence + 1))
      target="$dest/${base%.txt}_${sequence}.txt"
    done
    if [ ! -e "$target" ]; then
      cp -p "$file" "$target" || return 1
    fi
    [ "$file" != "$src/last" ] || last_target="$(basename "$target")"
  done

  if [ -n "$last_target" ]; then
    temporary_link="$(mktemp "$dest/.frost-last.XXXXXX")" || return 1
    if ! rm -f "$temporary_link" || ! ln -s "$last_target" "$temporary_link" || ! mv -f "$temporary_link" "$dest/last"; then
      rm -f "$temporary_link"
      return 1
    fi
  fi

  printf '%s\n' "$src" >"$marker" || return 1
  return 0
}

# Resolved save directory (protocol helpers keep the frost_* names).
# Prefer the configured path when writable; otherwise one-shot migrate to a fallback.
frost_dir() {
  local configured expanded fallback
  # Append a sentinel to distinguish newlines in the setting from the newline added by tmux.
  if configured="$(tmux show-option -gv '@frost-dir' 2>/dev/null; setting_status=$?; printf '\034'; exit "$setting_status")"; then
    configured="${configured%$'\034'}"
    if [ -z "$configured" ]; then
      configured="$default_frost_dir"
    else
      configured="${configured%$'\n'}"
    fi
  else
    configured="$default_frost_dir"
  fi
  expanded="$(expand_frost_dir_setting "$configured"; setting_status=$?; printf '\034'; exit "$setting_status")" || return 1
  expanded="${expanded%$'\034'}"
  if [ -n "$_frost_dir_cache" ] && [ "$_frost_dir_cache_key" = "$expanded" ]; then
    printf '%s\n' "$_frost_dir_cache"
    return 0
  fi
  validate_frost_dir_setting "$expanded" || return 1

  if frost_dir_is_writable "$expanded"; then
    _frost_dir_cache_key="$expanded"
    _frost_dir_cache="$expanded"
    printf '%s\n' "$_frost_dir_cache"
    return 0
  fi

  fallback="$default_frost_dir"
  if [ "$expanded" = "$fallback" ] || ! frost_dir_is_writable "$fallback"; then
    fallback="$default_frost_cache_dir"
  fi
  if ! frost_dir_is_writable "$fallback"; then
    echo "Glacier: save directory is not writable: $expanded" >&2
    return 1
  fi

  if [ -d "$expanded" ] && [ -r "$expanded" ]; then
    if migrate_frost_dir_once "$expanded" "$fallback"; then
      echo "Glacier: migrated frost saves from read-only $expanded to $fallback" >&2
    else
      echo "Glacier: failed to migrate frost saves from $expanded to $fallback" >&2
      return 1
    fi
  else
    echo "Glacier: using writable fallback save directory $fallback (configured path not writable: $expanded)" >&2
  fi

  _frost_dir_cache_key="$expanded"
  _frost_dir_cache="$fallback"
  printf '%s\n' "$_frost_dir_cache"
}

# Path for a new save file (timestamped).
frost_file_path() {
  local dir timestamp
  dir="$(frost_dir)" || return 1
  timestamp="$(date +"%Y%m%dT%H%M%S")"
  printf '%s\n' "${dir}/frost_${timestamp}.txt"
}

# Path to the "last" symlink.
last_frost_file() {
  local dir
  dir="$(frost_dir)" || return 1
  printf '%s\n' "${dir}/last"
}

# Display a message in the tmux status line.
# Use tmux's current display-time setting as-is when calling display-message.
# If a separate duration is specified, restore it after displaying for that duration (ms).
display_message() {
  local message="$1"
  local display_duration="$2"
  if [ -n "$display_duration" ]; then
    local saved_display_time
    saved_display_time="$(get_tmux_option "display-time" "750")"
    tmux set-option -gq display-time "$display_duration"
    tmux display-message "$message"
    tmux set-option -gq display-time "$saved_display_time"
  else
    tmux display-message "$message"
  fi
}

# ── Logging ────────────────────────────────────────────────────────

# Daily log file: frost_YYYY-MM-DD.log in the save directory.
# Keeps only the last 10 days of logs.

frost_log() {
  local level="$1"
  shift
  local dir log_file
  if ! dir="$(frost_dir)"; then
    echo "$(date +%H:%M:%S) [$level] $*" >&2
    return 0
  fi
  mkdir -p "$dir" 2>/dev/null || {
    echo "$(date +%H:%M:%S) [$level] $*" >&2
    return 0
  }
  log_file="$dir/frost_$(date +%Y-%m-%d).log"
  echo "$(date +%H:%M:%S) [$level] $*" >>"$log_file"
}

rotate_logs() {
  local dir
  dir="$(frost_dir)" || return 1
  find "$dir" -name "frost_*.log" -type f -mtime +10 -delete 2>/dev/null
}

# Return 1 if the lock is busy, or 2 if the save directory or lock file cannot be prepared.
# Uses flock on fd 9 — released automatically when the process exits.
acquire_lock() {
  local dir lock_file
  dir="$(frost_dir)" || return 2
  lock_file="$dir/.frost.lock"
  mkdir -p "$dir" || return 2

  # Use flock when the flock command is available.
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock_file" || return 2
    flock -n 9 || return 1
  else
    # If flock is unavailable (such as on macOS by default), use mkdir's atomicity for a directory lock.
    local lock_dir
    lock_dir="$dir/.frost.lock.d"
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$lock_dir/pid"
      trap release_lock EXIT INT TERM
      return 0
    else
      # Detect and clean up stale locks (when the process holding the lock has already exited).
      if [ -f "$lock_dir/pid" ]; then
        local lock_pid
        lock_pid="$(cat "$lock_dir/pid" 2>/dev/null)"
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
          rm -rf "$lock_dir"
          if mkdir "$lock_dir" 2>/dev/null; then
            echo "$$" > "$lock_dir/pid"
            trap release_lock EXIT INT TERM
            return 0
          fi
        fi
      fi
      return 1
    fi
  fi
}

release_lock() {
  local dir lock_dir
  dir="$(frost_dir)" || return 1
  lock_dir="$dir/.frost.lock.d"
  if [ -d "$lock_dir" ]; then
    local lock_pid
    lock_pid="$(cat "$lock_dir/pid" 2>/dev/null)"
    if [ "$lock_pid" = "$$" ]; then
      rm -rf "$lock_dir"
    fi
  fi
}

# Resolve symlink to absolute path (cross-platform alternative to readlink -f)
# Uses purely standard POSIX shell commands (no python/greadlink dependencies)
resolve_symlink() {
  local target="$1"
  [ -z "$target" ] && return
  (
    while [ -L "$target" ]; do
      local link
      link="$(readlink "$target")"
      cd "$(dirname "$target")" 2>/dev/null || break
      target="$link"
    done
    cd "$(dirname "$target")" 2>/dev/null && echo "$(pwd -P)/$(basename "$target")"
  )
}

# ── Auto-save script identity (path + inode/mtime) ─────────────────

# Fingerprint a script as "inode:mtime" (portable BSD/GNU stat).
# Empty output and non-zero status when the path is missing or unreadable.
frost_script_fingerprint() {
  local path="$1"
  local inode mtime
  if [ ! -e "$path" ]; then
    printf '%s\n' ""
    return 1
  fi
  if inode="$(stat -f '%i' "$path" 2>/dev/null)" && mtime="$(stat -f '%m' "$path" 2>/dev/null)"; then
    printf '%s\n' "${inode}:${mtime}"
    return 0
  fi
  if inode="$(stat -c '%i' "$path" 2>/dev/null)" && mtime="$(stat -c '%Y' "$path" 2>/dev/null)"; then
    printf '%s\n' "${inode}:${mtime}"
    return 0
  fi
  printf '%s\n' ""
  return 1
}

# Persist absolute paths + fingerprints used when the auto-save loop started.
# Sibling of .auto_save.pid so the pid file stays pid-only.
write_auto_save_meta() {
  local meta_file="$1"
  local loop_script="$2"
  local freeze_script="$3"
  local loop_fp freeze_fp
  loop_fp="$(frost_script_fingerprint "$loop_script")" || loop_fp=""
  freeze_fp="$(frost_script_fingerprint "$freeze_script")" || freeze_fp=""
  cat >"$meta_file" <<EOF
loop_path=${loop_script}
loop_fp=${loop_fp}
freeze_path=${freeze_script}
freeze_fp=${freeze_fp}
EOF
}

# True when meta matches the current loop/freeze script paths and fingerprints.
auto_save_meta_matches() {
  local meta_file="$1"
  local loop_script="$2"
  local freeze_script="$3"
  local stored_loop_path stored_loop_fp stored_freeze_path stored_freeze_fp
  local cur_loop_fp cur_freeze_fp

  [ -f "$meta_file" ] || return 1

  stored_loop_path="$(grep '^loop_path=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2-)"
  stored_loop_fp="$(grep '^loop_fp=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2-)"
  stored_freeze_path="$(grep '^freeze_path=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2-)"
  stored_freeze_fp="$(grep '^freeze_fp=' "$meta_file" 2>/dev/null | head -1 | cut -d= -f2-)"

  [ -n "$stored_loop_path" ] && [ -n "$stored_loop_fp" ] || return 1
  [ -n "$stored_freeze_path" ] && [ -n "$stored_freeze_fp" ] || return 1
  [ "$stored_loop_path" = "$loop_script" ] || return 1
  [ "$stored_freeze_path" = "$freeze_script" ] || return 1

  cur_loop_fp="$(frost_script_fingerprint "$loop_script")" || return 1
  cur_freeze_fp="$(frost_script_fingerprint "$freeze_script")" || return 1
  [ "$stored_loop_fp" = "$cur_loop_fp" ] || return 1
  [ "$stored_freeze_fp" = "$cur_freeze_fp" ] || return 1
  return 0
}

# True when @frost-thaw-confirm is on and any session has other than exactly one pane.
# Used only by the restore keybinding path; auto-restore never calls this.
frost_thaw_needs_confirm() {
  local enabled session count
  enabled="$(get_tmux_option "@frost-thaw-confirm" "off")"
  [ "$enabled" = "on" ] || return 1

  while IFS= read -r session; do
    [ -n "$session" ] || continue
    count="$(tmux list-panes -s -t "$session" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${count:-0}" -ne 1 ]; then
      return 0
    fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
  return 1
}
