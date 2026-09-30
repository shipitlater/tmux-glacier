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

# Copy existing frost saves once from a readable source into a writable destination.
migrate_frost_dir_once() {
  local src="$1"
  local dest="$2"
  local marker="$dest/.frost-migrated-from"
  local file base target

  mkdir -p "$dest" || return 1
  if [ -f "$marker" ]; then
    return 0
  fi

  for file in "$src"/frost_*.txt; do
    [ -e "$file" ] || continue
    base="$(basename "$file")"
    if [ ! -e "$dest/$base" ]; then
      cp -p "$file" "$dest/$base" || return 1
    fi
  done

  if [ -L "$src/last" ] || [ -f "$src/last" ]; then
    if [ -L "$src/last" ]; then
      target="$(readlink "$src/last")"
      if [ -n "$target" ] && [ ! -e "$dest/last" ] && [ ! -L "$dest/last" ]; then
        if [ -f "$dest/$target" ] || [ -f "$src/$target" ]; then
          [ -f "$dest/$target" ] || cp -p "$src/$target" "$dest/$target" || return 1
          ln -s "$target" "$dest/last" || return 1
        fi
      fi
    elif [ -f "$src/last" ] && [ ! -e "$dest/last" ]; then
      cp -p "$src/last" "$dest/last" || return 1
    fi
  fi

  printf '%s\n' "$src" >"$marker" || return 1
  return 0
}

# Resolved save directory (protocol helpers keep the frost_* names).
# Prefer the configured path when writable; otherwise one-shot migrate to a fallback.
frost_dir() {
  local configured expanded fallback
  configured="$(get_tmux_option "@frost-dir" "$default_frost_dir")"
  expanded="$(expand_frost_dir_setting "$configured")"
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
# display-message 호출 시 tmux의 현재 display-time 설정값을 그대로 사용한다.
# 별도 duration을 지정하면 그 시간(ms) 동안 표시 후 복원한다.
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
  dir="$(frost_dir)"
  find "$dir" -name "frost_*.log" -type f -mtime +10 -delete 2>/dev/null
}

# Acquire an exclusive lock (non-blocking). Returns 1 if lock held by another.
# Uses flock on fd 9 — released automatically when the process exits.
acquire_lock() {
  local lock_file
  lock_file="$(frost_dir)/.frost.lock"
  mkdir -p "$(frost_dir)"

  # flock 명령이 제공되는 경우 flock 사용
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lock_file"
    flock -n 9 || return 1
  else
    # flock이 없는 경우 (macOS 기본 환경 등) mkdir의 원자성을 이용한 디렉터리 락 사용
    local lock_dir
    lock_dir="$(frost_dir)/.frost.lock.d"
    if mkdir "$lock_dir" 2>/dev/null; then
      echo "$$" > "$lock_dir/pid"
      trap release_lock EXIT INT TERM
      return 0
    else
      # 고아 락 검출 및 정리 (락을 잡은 프로세스가 이미 종료된 경우)
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
  local lock_dir
  lock_dir="$(frost_dir)/.frost.lock.d"
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
