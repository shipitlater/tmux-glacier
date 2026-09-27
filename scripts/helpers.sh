#!/usr/bin/env bash

# tmux-glacier helpers — shared utilities for freeze and thaw

# shellcheck disable=SC2034  # used by sourcing scripts (freeze.sh, thaw.sh)
d=$'\t'

default_frost_dir="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/glacier"

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

# Resolved frost save directory.
frost_dir() {
  local path
  path="$(get_tmux_option "@frost-dir" "$default_frost_dir")"
  # expand ~ and $HOME
  echo "$path" | sed "s,\$HOME,$HOME,g; s,\~,$HOME,g"
}

# Path for a new save file (timestamped).
frost_file_path() {
  local timestamp
  timestamp="$(date +"%Y%m%dT%H%M%S")"
  echo "$(frost_dir)/frost_${timestamp}.txt"
}

# Path to the "last" symlink.
last_frost_file() {
  echo "$(frost_dir)/last"
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

# Daily log file: frost_YYYY-MM-DD.log in the frost directory.
# Keeps only the last 10 days of logs.

frost_log() {
  local level="$1"
  shift
  local dir
  dir="$(frost_dir)"
  mkdir -p "$dir"
  local log_file
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
