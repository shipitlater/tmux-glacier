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

# 실행 중 사용하는 Base64 디코더 옵션을 한 번 판별한다.
init_base64_decoder() {
  if [ -n "${BASE64_DECODER_FLAG:-}" ]; then
    return 0
  fi

  local __glacier_probe
  if __glacier_probe="$(printf 'Zg==' | base64 -d 2>/dev/null)" && [ "$__glacier_probe" = f ]; then
    BASE64_DECODER_FLAG=-d
  elif __glacier_probe="$(printf 'Zg==' | base64 -D 2>/dev/null)" && [ "$__glacier_probe" = f ]; then
    BASE64_DECODER_FLAG=-D
  else
    return 1
  fi
}

# 플랫폼별 줄바꿈을 제거하되 인코더의 종료 상태를 유지한다.
encode_base64() (
  set -o pipefail
  base64 | tr -d '\r\n'
)

# 디코딩이 완전히 성공한 뒤에만 원본 바이트를 내보낸다.
decode_base64() {
  init_base64_decoder || return 1

  local __glacier_payload __glacier_pattern __glacier_file __glacier_reencoded
  __glacier_payload="$(cat; __glacier_status=$?; printf '\034'; exit "$__glacier_status")" || return 1
  __glacier_payload="${__glacier_payload%$'\034'}"
  __glacier_pattern='^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$'
  if [ -n "$__glacier_payload" ] && ! [[ "$__glacier_payload" =~ $__glacier_pattern ]]; then
    return 1
  fi

  __glacier_file="$(mktemp "${TMPDIR:-/tmp}/tmux-glacier-b64.XXXXXX")" || return 1
  if ! printf '%s' "$__glacier_payload" | base64 "$BASE64_DECODER_FLAG" >"$__glacier_file" 2>/dev/null; then
    rm -f "$__glacier_file"
    return 1
  fi
  __glacier_reencoded="$(encode_base64 <"$__glacier_file")" || {
    rm -f "$__glacier_file"
    return 1
  }
  if [ "$__glacier_reencoded" != "$__glacier_payload" ]; then
    rm -f "$__glacier_file"
    return 1
  fi
  cat "$__glacier_file"
  local __glacier_status=$?
  rm -f "$__glacier_file"
  return "$__glacier_status"
}

# tmux argv의 마지막 세미콜론만 명령 구분에서 보호한다.
escape_tmux_argument() {
  local __glacier_argument="$1"
  case "$__glacier_argument" in
    *';') __glacier_argument="${__glacier_argument%?}\\;" ;;
  esac
  printf -v "$2" '%s' "$__glacier_argument"
}

# 이름에 대한 format 보호와 argv 보호를 각각 한 번 적용한다.
prepare_tmux_option_name() {
  local __glacier_prepared_name="${1//#/##}"
  escape_tmux_argument "$__glacier_prepared_name" "$2"
}

# tmux가 덧붙인 출력용 개행 한 개만 제거한다.
capture_option_value() {
  local __glacier_target __glacier_name __glacier_output
  case "$2" in @*) ;; *) return 1 ;; esac
  escape_tmux_argument "$1" __glacier_target
  prepare_tmux_option_name "$2" __glacier_name
  __glacier_output="$(tmux -u show-options -pv -t "$__glacier_target" "$__glacier_name"; __glacier_status=$?; printf '\034'; exit "$__glacier_status")" || return 1
  __glacier_output="${__glacier_output%$'\034'}"
  case "$__glacier_output" in *$'\n') ;; *) return 1 ;; esac
  __glacier_output="${__glacier_output%$'\n'}"
  printf -v "$3" '%s' "$__glacier_output"
}

# Base64 필드를 개행 손실 없이 출력 변수로 복원한다.
decode_option_field() {
  case "$1" in b64:*) ;; *) return 1 ;; esac
  init_base64_decoder || return 1
  local __glacier_decoded
  __glacier_decoded="$(printf '%s' "${1#b64:}" | decode_base64; __glacier_status=$?; printf '\034'; exit "$__glacier_status")" || return 1
  __glacier_decoded="${__glacier_decoded%$'\034'}"
  printf -v "$2" '%s' "$__glacier_decoded"
}

# 전체 표시와 이름 직접 조회의 정확한 출력 경계로 local 이름을 확정한다.
list_pane_user_option_names() {
  local LC_ALL=C
  local __glacier_target __glacier_remaining __glacier_query __glacier_candidate
  local __glacier_prepared __glacier_previous='' __glacier_result='' __glacier_encoded
  local __glacier_index __glacier_found
  escape_tmux_argument "$1" __glacier_target
  __glacier_remaining="$(tmux -u show-options -p -t "$__glacier_target"; __glacier_status=$?; printf '\034'; exit "$__glacier_status")" || return 1
  __glacier_remaining="${__glacier_remaining%$'\034'}"

  if [[ "$__glacier_remaining" != @* ]]; then
    if [[ "$__glacier_remaining" != *$'\n'@* ]]; then
      return 0
    fi
    __glacier_remaining="@${__glacier_remaining#*$'\n'@}"
  fi

  while [[ "$__glacier_remaining" == @* ]]; do
    __glacier_found=false
    for ((__glacier_index = 1; __glacier_index < ${#__glacier_remaining}; __glacier_index++)); do
      [ "${__glacier_remaining:__glacier_index:1}" = ' ' ] || continue
      __glacier_candidate="${__glacier_remaining:0:__glacier_index}"
      if [ -n "$__glacier_previous" ] && ! [[ "$__glacier_candidate" > "$__glacier_previous" ]]; then
        continue
      fi
      prepare_tmux_option_name "$__glacier_candidate" __glacier_prepared
      __glacier_query="$(tmux -u show-options -p -t "$__glacier_target" "$__glacier_prepared" 2>/dev/null; __glacier_status=$?; printf '\034'; exit "$__glacier_status")" || continue
      __glacier_query="${__glacier_query%$'\034'}"
      case "$__glacier_query" in *$'\n') ;; *) continue ;; esac
      [ "${__glacier_query:0:${#__glacier_candidate}}" = "$__glacier_candidate" ] || continue
      [ "${__glacier_query:${#__glacier_candidate}:1}" = ' ' ] || continue
      [ "${__glacier_remaining:0:${#__glacier_query}}" = "$__glacier_query" ] || continue
      __glacier_encoded="$(printf '%s' "$__glacier_candidate" | encode_base64)" || return 1
      __glacier_result="${__glacier_result}b64:${__glacier_encoded}"$'\n'
      __glacier_previous="$__glacier_candidate"
      __glacier_remaining="${__glacier_remaining:${#__glacier_query}}"
      __glacier_found=true
      break
    done
    [ "$__glacier_found" = true ] || return 1
  done
  printf '%s' "$__glacier_result"
}
