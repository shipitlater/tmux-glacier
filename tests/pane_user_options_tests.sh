#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/helpers.sh
source "$SCRIPT_DIR/../scripts/helpers.sh"
# shellcheck source=../scripts/pane_user_options.sh
source "$SCRIPT_DIR/../scripts/pane_user_options.sh"

passed=0
failed=0

check() {
  local description="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    printf '통과: %s\n' "$description" >&2
  else
    failed=$((failed + 1))
    printf '실패: %s\n' "$description" >&2
  fi
}

check_required() {
  local description="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    printf '통과: %s\n' "$description" >&2
  else
    failed=$((failed + 1))
    printf '실패: %s\n' "$description" >&2
    return 1
  fi
}

same_file() { cmp -s "$1" "$2"; }
is_empty() { [ ! -s "$1" ]; }
fails() { ! "$@"; }

test_codec_bytes() {
  local source_file encoded_file decoded_file field_value i
  source_file="$(mktemp)" || return 1
  encoded_file="$(mktemp)" || return 1
  decoded_file="$(mktemp)" || return 1

  : >"$source_file"
  check '빈 바이트를 한 줄로 인코딩' encode_base64 <"$source_file" >"$encoded_file"
  check '빈 Base64 payload' is_empty "$encoded_file"
  field_value=unchanged
  check 'b64: 빈 값 디코딩' decode_option_field 'b64:' field_value
  check '빈 값의 정확한 복원' test -z "$field_value"
  check '필드 디코더 선택을 부모 셸에 보관' test -n "${BASE64_DECODER_FLAG:-}"

  printf '한글\t"따옴표"\\역슬래시\n중간\n\n' >"$source_file"
  i=0
  while [ "$i" -lt 240 ]; do printf 'x' >>"$source_file"; i=$((i + 1)); done
  printf '\n\n' >>"$source_file"
  check '긴 복합 바이트 인코딩' encode_base64 <"$source_file" >"$encoded_file"
  check '긴 Base64가 한 줄' test "$(wc -l <"$encoded_file" | tr -d ' ')" -eq 0
  check '긴 복합 바이트 디코딩' decode_base64 <"$encoded_file" >"$decoded_file"
  check '긴 복합 바이트 일치' same_file "$source_file" "$decoded_file"
  field_value=unchanged
  check '필드의 끝 개행 보존' decode_option_field "b64:$(cat "$encoded_file")" field_value
  printf '%s' "$field_value" >"$decoded_file"
  check '필드 바이트 일치' same_file "$source_file" "$decoded_file"
  check '접두사 없는 필드 거부' fails decode_option_field 'QQ==' field_value

  for bad in 'A' 'QQ=' 'QQ===' 'Q=Q=' 'QQ==A' 'Q?==' 'Q Q=' $'QQ==\n'; do
    printf '%s' "$bad" >"$encoded_file"
    check '잘못된 Base64 거부' fails decode_base64 <"$encoded_file" >"$decoded_file"
    check '잘못된 Base64 부분 출력 차단' is_empty "$decoded_file"
  done
  rm -f "$source_file" "$encoded_file" "$decoded_file"
}

test_decoder_portability() {
  local decoder_mode encoded_file decoded_file
  encoded_file="$(mktemp)" || return 1
  decoded_file="$(mktemp)" || return 1
  printf 'QUJD' >"$encoded_file"
  decoder_mode=bsd
  base64() {
    if [ "$decoder_mode" = bsd ]; then
      case "${1:-}" in
        -d) return 2 ;;
        -D) shift; command base64 -d "$@"; return $? ;;
      esac
    fi
    if [ "$decoder_mode" = broken ] && [ "${1:-}" = -d ]; then
      printf 'A'
      return 37
    fi
    command base64 "$@"
  }
  unset BASE64_DECODER_FLAG
  check 'BSD 디코더 선택' init_base64_decoder
  check 'BSD 디코더 플래그' test "${BASE64_DECODER_FLAG:-}" = -D
  check 'BSD 디코더 사용' decode_base64 <"$encoded_file" >"$decoded_file"
  check 'BSD 디코딩 결과' test "$(cat "$decoded_file")" = ABC
  decoder_mode=gnu
  unset BASE64_DECODER_FLAG
  check 'GNU 디코더 선택' init_base64_decoder
  check 'GNU 디코더 플래그' test "${BASE64_DECODER_FLAG:-}" = -d
  decoder_mode=broken
  check '부분 출력 후 디코더 실패 전파' fails decode_base64 <"$encoded_file" >"$decoded_file"
  check '실패한 디코더 출력 폐기' is_empty "$decoded_file"
  unset -f base64
  unset BASE64_DECODER_FLAG
  base64() { printf 'QUJD'; return 38; }
  check '인코더 실패 전파' fails encode_base64 <"$encoded_file" >"$decoded_file"
  unset -f base64
  rm -f "$encoded_file" "$decoded_file"
}

test_capture_failure() {
  local captured output_file
  output_file="$(mktemp)" || return 1
  tmux() {
    case "$*" in
      *'@missing'*) printf '일부\n'; return 41 ;;
      *'@empty'*) printf '\n'; return 0 ;;
      *'@gone'*) return 0 ;;
      *) printf '한글\n끝\n\n\n'; return 0 ;;
    esac
  }
  captured=unchanged
  check '조회 실패 상태 전파' fails capture_option_value '%1' '@missing' captured
  check '조회 실패 시 출력 변수 보존' test "$captured" = unchanged
  check '출력 terminator 없는 조회 거부' fails capture_option_value '%1' '@gone' captured
  check '빈 값 조회' capture_option_value '%1' '@empty' captured
  check '빈 값 유지' test -z "$captured"
  check '끝 개행 두 개 조회' capture_option_value '%1' '@multi' captured
  printf '%s' "$captured" >"$output_file"
  check '끝 개행 두 개 보존' test "$(od -An -tx1 "$output_file" | tr -d ' \n')" = 'ed959ceab8800aeb819d0a0a'
  unset -f tmux
  rm -f "$output_file"
}

test_argument_and_names() {
  local value expected_file actual_file
  escape_tmux_argument 'x\\;' value
  check '끝 세미콜론 보호' test "$value" = 'x\\\;'
  escape_tmux_argument 'a;b' value
  check '중간 세미콜론 보존' test "$value" = 'a;b'
  prepare_tmux_option_name '@#;name;' value
  check '이름의 #와 끝 세미콜론 보호' test "$value" = '@##;name\;'

  expected_file="$(mktemp)" || return 1
  actual_file="$(mktemp)" || return 1
  printf 'b64:QA==\nb64:QGEgYg==\nb64:QGMKI2Q=\n' >"$expected_file"
  tmux() {
    case "$*" in
      *' @') printf '@ \n' ;;
      *' @a') return 1 ;;
      *' @a b') printf '@a b 값\n' ;;
      *' @c'$'\n''##d') printf '@c\n#d 값\n' ;;
      *) printf '@ \n@a b 값\n@c\n#d 값\nremain-on-exit off\n' ;;
    esac
  }
  check '공백·개행 이름의 후보 경계 열거' list_pane_user_option_names '%1' >"$actual_file"
  check '이름만 Base64로 반환' same_file "$expected_file" "$actual_file"
  unset -f tmux
  rm -f "$expected_file" "$actual_file"
}

test_real_tmux_names() {
  local socket pane_id expected_file actual_file captured
  socket="/tmp/glacier-pane-options-$$.sock"
  expected_file="$(mktemp)" || return 1
  actual_file="$(mktemp)" || return 1
  tmux() { command tmux -S "$socket" "$@"; }
  if ! tmux -f /dev/null new-session -d -s pane-options 'sleep 60'; then
    printf '실패: 독립 tmux 서버 시작\n' >&2
    failed=$((failed + 1))
    unset -f tmux
    rm -f "$expected_file" "$actual_file" "$socket"
    return
  fi
  pane_id="$(tmux list-panes -t pane-options -F '#{pane_id}')"
  if [ -z "$pane_id" ]; then
    printf '실패: 독립 tmux pane 조회\n' >&2
    failed=$((failed + 1))
    unset -f tmux
    rm -f "$expected_file" "$actual_file" "$socket"
    return
  fi
  tmux -u set-option -g '@global' '상위 값'
  tmux -u set-option -w -t pane-options:0 '@window' '창 값'
  tmux -u set-option -p -t "$pane_id" remain-on-exit on
  tmux -u set-option -p -t "$pane_id" '@' ''
  tmux -u set-option -p -t "$pane_id" '@a b' '공백 값'
  tmux -u set-option -p -t "$pane_id" $'@c\n##d' $'한글\n끝\n\n'
  tmux -u set-option -p -t "$pane_id" '@semi\;' '세미콜론\;'
  printf 'b64:QA==\nb64:QGEgYg==\nb64:QGMKI2Q=\nb64:QHNlbWk7\n' >"$expected_file"
  check '실제 tmux의 local 특수 이름 열거' list_pane_user_option_names "$pane_id" >"$actual_file"
  check '실제 tmux에서 상위 scope·built-in 제외' same_file "$expected_file" "$actual_file"
  captured=unchanged
  check '실제 tmux에서 개행 값 조회' capture_option_value "$pane_id" $'@c\n#d' captured
  printf '%s' "$captured" >"$actual_file"
  printf '한글\n끝\n\n' >"$expected_file"
  check '실제 tmux의 끝 개행 보존' same_file "$expected_file" "$actual_file"
  captured=unchanged
  check '실제 tmux에서 끝 세미콜론 이름 조회' capture_option_value "$pane_id" '@semi;' captured
  check '실제 tmux에서 끝 세미콜론 값 보존' test "$captured" = '세미콜론;'
  tmux kill-server 2>/dev/null || true
  unset -f tmux
  rm -f "$expected_file" "$actual_file" "$socket"
}

freeze_test_setup() {
  freeze_test_original_path="$PATH"
  freeze_test_original_tmux="${TMUX:-}"
  freeze_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/glacier-freeze-test.XXXXXX")" || return 1
  mkdir -p "$freeze_test_dir/bin" "$freeze_test_dir/saves" || return 1
  GLACIER_REAL_TMUX="$(command -v tmux)"
  GLACIER_REAL_BASE64="$(command -v base64)"
  GLACIER_TEST_SOCKET="$freeze_test_dir/socket"
  GLACIER_TEST_DIR="$freeze_test_dir"
  export GLACIER_REAL_TMUX GLACIER_REAL_BASE64 GLACIER_TEST_SOCKET GLACIER_TEST_DIR
  TMUX="$GLACIER_TEST_SOCKET,1,0"
  export TMUX
  cat >"$freeze_test_dir/bin/tmux" <<'EOF'
#!/bin/sh
case "${GLACIER_FAIL_MODE:-}" in
  query) case " $* " in *' show-options -pv '*) exit 37 ;; esac ;;
  dump) case " $* " in *' list-panes -a '*) exit 38 ;; esac ;;
esac
if [ "${1:-}" = -u ] && [ "${2:-}" = show-options ] && [ "${3:-}" = -p ] && [ "$#" -eq 5 ] && [ "${5:-}" = "${GLACIER_FAIL_PANE:-}" ] && [ "${GLACIER_FAIL_MODE:-}" = thaw-list ]; then
  printf '@부분 값\n'
  exit 40
fi
if [ "${1:-}" = -u ] && [ "${2:-}" = set-option ]; then
  case "${3:-}" in
    -up|-p)
      if [ -n "${GLACIER_TRACE:-}" ]; then
        printf '%s\t%s\t%s\n' "$3" "$5" "$6" >>"$GLACIER_TRACE"
      fi
      if [ "${5:-}" = "${GLACIER_FAIL_PANE:-}" ]; then
        case "${GLACIER_FAIL_MODE:-}:$3:${6:-}" in
          thaw-unset:-up:*) printf '노출금지진단\n' >&2; exit 41 ;;
          thaw-set:-p:@foo) [ "${7:-}" != B ] || exit 43 ;;
          thaw-set:-p:@fail) printf '노출금지진단\n' >&2; exit 42 ;;
        esac
      fi
      ;;
  esac
fi
exec "$GLACIER_REAL_TMUX" -S "$GLACIER_TEST_SOCKET" "$@"
EOF
  cat >"$freeze_test_dir/bin/base64" <<'EOF'
#!/bin/sh
if [ "${GLACIER_FAIL_MODE:-}" = encode ]; then
  printf '부분 출력'
  exit 39
fi
exec "$GLACIER_REAL_BASE64" "$@"
EOF
  cat >"$freeze_test_dir/bin/mktemp" <<'EOF'
#!/bin/sh
if [ "${GLACIER_FAIL_MODE:-}" = write ] && [ "$#" -eq 1 ]; then
  mkdir -p "$GLACIER_TEST_DIR/write-failure"
  printf '%s\n' "$GLACIER_TEST_DIR/write-failure"
  exit 0
fi
exec /usr/bin/mktemp "$@"
EOF
  cat >"$freeze_test_dir/bin/date" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = '+%Y%m%dT%H%M%S' ]; then
  printf '20260930T120000\n'
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "$freeze_test_dir/bin/"*
  PATH="$freeze_test_dir/bin:$PATH"
  export PATH
  tmux -f /dev/null new-session -d -s freeze-options 'sleep 60' || return 1
  tmux -u set-option -g '@frost-dir' "$freeze_test_dir/saves" || return 1
  unset GLACIER_FAIL_MODE
}

freeze_test_cleanup() {
  if [ -n "${GLACIER_TEST_SOCKET:-}" ] && [ -S "$GLACIER_TEST_SOCKET" ] && [ -n "${GLACIER_REAL_TMUX:-}" ]; then
    "$GLACIER_REAL_TMUX" -S "$GLACIER_TEST_SOCKET" kill-server 2>/dev/null || true
  fi
  if [ -n "${freeze_test_dir:-}" ]; then
    rm -rf "$freeze_test_dir"
  fi
  if [ -n "${freeze_test_original_path:-}" ]; then
    PATH="$freeze_test_original_path"
    export PATH
  fi
  TMUX="${freeze_test_original_tmux:-}"
  export TMUX
  unset GLACIER_TRACE GLACIER_FAIL_PANE GLACIER_FAIL_MODE GLACIER_REAL_TMUX GLACIER_REAL_BASE64 GLACIER_TEST_SOCKET GLACIER_TEST_DIR freeze_test_dir freeze_test_original_path freeze_test_original_tmux
}

run_real_freeze() {
  /bin/bash "$SCRIPT_DIR/../scripts/freeze.sh" quiet >/dev/null 2>&1
}

test_freeze_records() {
  freeze_test_setup || return 1
  local first snapshot
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')"
  tmux -u set-option -p -t "$first" '@project' ninetoten || return 1
  tmux split-window -d -t "$first" 'sleep 60' || return 1
  check '실제 Freeze 저장 성공' run_real_freeze
  snapshot="$freeze_test_dir/saves/last"
  check '두 pane의 마커 기록' test "$(awk -F '\t' '$1 == "pane_user_options" {n++} END {print n+0}' "$snapshot")" -eq 2
  check '옵션 없는 pane의 마커 기록' test "$(awk -F '\t' '$1 == "pane_user_options" && $4 == 1 {n++} END {print n+0}' "$snapshot")" -eq 1
  check '마커 4필드와 옵션 6필드' awk -F '\t' '$1 == "pane_user_options" && NF != 4 {exit 1} $1 == "pane_user_option" && NF != 6 {exit 1}' "$snapshot"
  check 'pane 식별자에 연결된 Base64 옵션' awk -F '\t' '$1 == "pane_user_option" {if ($2 == "freeze-options" && $3 == 0 && $4 == 0 && $5 == "b64:QHByb2plY3Q=" && $6 == "b64:bmluZXRvdGVu") n++} END {exit !(n == 1)}' "$snapshot"
  check '반복 저장 내용 비교' run_real_freeze
  check '반복 저장에서 파일 하나 유지' test "$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')" -eq 1
  freeze_test_cleanup
}

test_freeze_scope() {
  freeze_test_setup || return 1
  local pane snapshot
  pane="$(tmux list-panes -t freeze-options -F '#{pane_id}')"
  tmux -u set-option -g '@global-only' global || return 1
  tmux -u set-option -w -t freeze-options:0 '@window-only' window || return 1
  tmux -u set-option -p -t "$pane" remain-on-exit on || return 1
  tmux -u set-option -p -t "$pane" '@local' local || return 1
  check 'scope 분리 저장 성공' run_real_freeze
  snapshot="$freeze_test_dir/saves/last"
  check 'local 옵션만 한 건 저장' test "$(awk -F '\t' '$1 == "pane_user_option" {n++} END {print n+0}' "$snapshot")" -eq 1
  check '상위 scope와 built-in 제외' awk -F '\t' '$1 == "pane_user_option" {exit !($5 == "b64:QGxvY2Fs" && $6 == "b64:bG9jYWw=")}' "$snapshot"
  freeze_test_cleanup
}

test_freeze_failure_keeps_last() {
  freeze_test_setup || return 1
  local pane snapshot old_target mode old_log_count
  pane="$(tmux list-panes -t freeze-options -F '#{pane_id}')"
  tmux -u set-option -p -t "$pane" '@fault' before || return 1
  check '기준 Freeze 저장 성공' run_real_freeze
  snapshot="$freeze_test_dir/saves/last"
  old_target="$(readlink "$snapshot")"
  cp "$snapshot" "$freeze_test_dir/original" || return 1
  tmux -u set-option -p -t "$pane" '@fault' after || return 1
  old_log_count="$(grep -c 'freeze complete' "$freeze_test_dir/saves"/*.log || true)"
  for mode in query encode write dump; do
    GLACIER_FAIL_MODE="$mode"
    export GLACIER_FAIL_MODE
    check "${mode} 실패 전파" fails run_real_freeze
    check "${mode} 실패 후 대상 바이트 보존" same_file "$snapshot" "$freeze_test_dir/original"
    check "${mode} 실패 후 last 보존" test "$(readlink "$snapshot")" = "$old_target"
    check "${mode} 실패 후 성공 로그 없음" test "$(grep -c 'freeze complete' "$freeze_test_dir/saves"/*.log || true)" = "$old_log_count"
    unset GLACIER_FAIL_MODE
  done
  check '실패한 임시 스냅샷 정리' test "$(find "$freeze_test_dir/saves" -name '.frost-*' | wc -l | tr -d ' ')" -eq 0
  check '같은 초 변경 저장 성공' run_real_freeze
  check '같은 초 변경 시 새 파일 발행' test "$(readlink "$snapshot")" != "$old_target"
  check '같은 초 변경 후 이전 파일 보존' same_file "$freeze_test_dir/saves/$old_target" "$freeze_test_dir/original"
  freeze_test_cleanup
}

run_freeze_test() {
  local description="$1"
  shift
  if ! "$@"; then
    failed=$((failed + 1))
    printf '실패: %s 준비 또는 실행\n' "$description" >&2
    freeze_test_cleanup
  fi
}

run_real_thaw() {
  /bin/bash "$SCRIPT_DIR/../scripts/thaw.sh" >"$freeze_test_dir/thaw-output" 2>&1
}

write_thaw_snapshot() {
  printf 'frost_version\t1\n' >"$freeze_test_dir/saves/manual.txt" || return 1
  cat >>"$freeze_test_dir/saves/manual.txt" || return 1
  ln -sf manual.txt "$freeze_test_dir/saves/last"
}

pane_value_is() {
  local actual
  capture_option_value "$1" "$2" actual && [ "$actual" = "$3" ]
}

pane_option_absent() {
  local actual
  ! capture_option_value "$1" "$2" actual 2>/dev/null
}

test_replace_and_empty_marker() {
  freeze_test_setup || return 1
  local first second
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  second="$(tmux split-window -d -P -F '#{pane_id}' -t "$first" 'sleep 60')" || return 1
  tmux -u set-option -p -t "$first" '@foo' A || return 1
  tmux -u set-option -g '@global-only' global || return 1
  tmux -u set-option -w -t freeze-options:0 '@window-only' window || return 1
  tmux -u set-option -p -t "$first" remain-on-exit on || return 1
  run_real_freeze || return 1
  tmux -u set-option -p -t "$first" '@foo' OLD || return 1
  tmux -u set-option -p -t "$first" '@bar' B || return 1
  tmux -u set-option -p -t "$second" '@stale' C || return 1
  check '실제 Thaw 교체 성공' run_real_thaw
  check '@foo 스냅샷 값 복원' pane_value_is "$first" '@foo' A
  check 'stale @bar 제거' pane_option_absent "$first" '@bar'
  check '빈 마커의 local 전체 제거' pane_option_absent "$second" '@stale'
  check 'built-in 보존' test "$(tmux show-options -pv -t "$first" remain-on-exit)" = on
  check 'global 보존' test "$(tmux show-options -gv '@global-only')" = global
  check 'window 보존' test "$(tmux show-options -wv -t freeze-options:0 '@window-only')" = window
  tmux -u set-option -p -t "$first" '@bar' again || return 1
  check '반복 Thaw 성공' run_real_thaw
  check '반복 Thaw도 stale 제거' pane_option_absent "$first" '@bar'
  check '반복 Thaw pane 수 보존' test "$(tmux list-panes -t freeze-options | wc -l | tr -d ' ')" -eq 2
  freeze_test_cleanup
}

test_legacy_and_orphan() {
  freeze_test_setup || return 1
  local first
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@foo' OLD || return 1
  write_thaw_snapshot </dev/null || return 1
  check '구형 스냅샷 Thaw 성공' run_real_thaw
  check '구형 스냅샷 local 보존' pane_value_is "$first" '@foo' OLD
  printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n' | write_thaw_snapshot || return 1
  run_real_thaw || true
  check 'orphan 옵션 무시' pane_value_is "$first" '@foo' OLD
  check 'orphan 로그 기록' grep -q '마커' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_corrupt_pane_isolation() {
  freeze_test_setup || return 1
  local first second record
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  second="$(tmux split-window -d -P -F '#{pane_id}' -t "$first" 'sleep 60')" || return 1
  GLACIER_TRACE="$freeze_test_dir/trace"
  export GLACIER_TRACE
  for record in \
    $'pane_user_option\tfreeze-options\t0\t0' \
    $'pane_user_option\tfreeze-options\t0\t0\t\tb64:QQ==' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\t' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\textra' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\t' \
    $'pane_user_option\tfreeze-options\t0\t0\tQGZvbw==\tb64:QQ==' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tQQ==' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:***\tb64:QQ==' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:***' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:cmVtYWluLW9uLWV4aXQ=\tb64:QQ==' \
    $'pane_user_option\tfreeze-options\t0\t0\tb64:\tb64:QQ=='; do
    tmux -u set-option -p -t "$first" '@foo' OLD || return 1
    tmux -u set-option -p -t "$second" '@foo' OLD || return 1
    {
      printf 'pane_user_options\tfreeze-options\t0\t0\n'
      printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n'
      printf '%s\n' "$record"
      printf 'pane_user_options\tfreeze-options\t0\t1\n'
      printf 'pane_user_option\tfreeze-options\t0\t1\tb64:QGZvbw==\tb64:Qg==\n'
    } | write_thaw_snapshot || return 1
    : >"$GLACIER_TRACE"
    check '손상 레코드 Thaw 실패 상태' fails run_real_thaw
    check '손상 pane의 기존 옵션 보존' pane_value_is "$first" '@foo' OLD
    check '다른 정상 pane은 계속 복원' pane_value_is "$second" '@foo' B
    check '손상 pane에는 unset/set 호출 없음' fails grep -Fq "$first" "$GLACIER_TRACE"
  done
  check '부분 복원 성공 로그 없음' fails grep -q 'thaw complete' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_corrupt_marker_isolation() {
  freeze_test_setup || return 1
  local first malformed order
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  for malformed in \
    $'pane_user_options\tfreeze-options\t0\t0\textra' \
    $'pane_user_options\tfreeze-options\t0\t0\t'; do
    for order in before after; do
      tmux -u set-option -p -t "$first" '@foo' OLD || return 1
      tmux -u set-option -p -t "$first" '@stale' CURRENT || return 1
      {
        [ "$order" != before ] || printf '%s\n' "$malformed"
        printf 'pane_user_options\tfreeze-options\t0\t0\n'
        printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n'
        [ "$order" != after ] || printf '%s\n' "$malformed"
      } | write_thaw_snapshot || return 1
      check '손상 마커 진단 시 실패 상태' fails run_real_thaw
      check '손상 마커와 유효 마커가 함께 있으면 정상 옵션 복원' pane_value_is "$first" '@foo' A
      check '손상 마커가 정상 교체를 막지 않음' pane_option_absent "$first" '@stale'
      check '손상 마커 진단 기록' grep -q '마커 검증 실패' "$freeze_test_dir/saves/"*.log
    done
    tmux -u set-option -p -t "$first" '@foo' OLD || return 1
    printf '%s\n' "$malformed" | write_thaw_snapshot || return 1
    check '유효 마커가 없으면 실패 상태' fails run_real_thaw
    check '유효 마커가 없으면 기존 옵션 보존' pane_value_is "$first" '@foo' OLD
  done
  freeze_test_cleanup
}

test_exact_targets_and_duplicates() {
  freeze_test_setup || return 1
  local first record
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@foo' OLD || return 1
  GLACIER_TRACE="$freeze_test_dir/trace"
  export GLACIER_TRACE
  for record in \
    $'pane_user_options\tfreeze\t0\t0' \
    $'pane_user_options\tfreeze-options\t0\t99' \
    $'pane_user_options\tfreeze-options\t99\t0'; do
    printf '%s\n' "$record" | write_thaw_snapshot || return 1
    : >"$GLACIER_TRACE"
    check '고아 대상 pane은 WARN 성공' run_real_thaw
    check '고아 thaw WARN 기록' grep -q '고아 thaw' "$freeze_test_dir/saves/"*.log
    check '고아 thaw가 기존 옵션 유지' pane_value_is "$first" '@foo' OLD
    check '고아 대상에는 unset/set 호출 없음' is_empty "$GLACIER_TRACE"
  done
  for record in \
    $'pane_user_options\t\t0\t0' \
    $'pane_user_options\tfreeze-options\t\t0' \
    $'pane_user_options\tfreeze-options\t0\t' \
    $'pane_user_options\tfreeze-options\tx\t0' \
    $'pane_user_options\tfreeze-options\t0\tx' \
    $'pane_user_options\tfreeze-options\t-1\t0' \
    $'pane_user_options\tfreeze-options\t0\t-1'; do
    printf '%s\n' "$record" | write_thaw_snapshot || return 1
    : >"$GLACIER_TRACE"
    check '잘못된 식별자 실패 상태' fails run_real_thaw
    check '유사 세션·현재 pane fallback 없음' pane_value_is "$first" '@foo' OLD
    check '잘못된 대상에는 unset/set 호출 없음' is_empty "$GLACIER_TRACE"
  done
  {
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n'
    printf 'pane_user_options\tfreeze-options\t0\t0\n'
    printf 'pane_user_options\tfreeze-options\t0\t0\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:Qg==\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGVtcHR5\tb64:\n'
  } | write_thaw_snapshot || return 1
  : >"$GLACIER_TRACE"
  check '중복 마커와 역순 레코드 복원 성공' run_real_thaw
  check '중복 이름의 마지막 값 적용' pane_value_is "$first" '@foo' B
  check '빈 값은 unset과 구분' pane_value_is "$first" '@empty' ''
  check '중복 마커도 기존 옵션 삭제 한 번' test "$(awk -F '\t' '$1 == "-up" {n++} END {print n+0}' "$GLACIER_TRACE")" -eq 1
  freeze_test_cleanup
}

test_thaw_command_failures() {
  freeze_test_setup || return 1
  local first second mode
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  second="$(tmux split-window -d -P -F '#{pane_id}' -t "$first" 'sleep 60')" || return 1
  GLACIER_TRACE="$freeze_test_dir/trace"
  GLACIER_FAIL_PANE="$first"
  export GLACIER_TRACE GLACIER_FAIL_PANE
  {
    printf 'pane_user_options\tfreeze-options\t0\t0\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZhaWw=\tb64:bm8tbG9nLXNlY3JldA==\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:Qg==\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGFmdGVy\tb64:Qw==\n'
    printf 'pane_user_options\tfreeze-options\t0\t1\n'
    printf 'pane_user_option\tfreeze-options\t0\t1\tb64:QGZvbw==\tb64:Qg==\n'
  } | write_thaw_snapshot || return 1
  for mode in thaw-list thaw-unset thaw-set; do
    tmux -u set-option -p -t "$first" '@foo' OLD || return 1
    tmux -u set-option -p -t "$first" '@stale' OLD || return 1
    tmux -u set-option -p -t "$second" '@foo' OLD || return 1
    : >"$GLACIER_TRACE"
    GLACIER_FAIL_MODE="$mode"
    export GLACIER_FAIL_MODE
    check "${mode} 실패 상태 전파" fails run_real_thaw
    unset GLACIER_FAIL_MODE
    check "${mode} 다른 pane 계속 복원" pane_value_is "$second" '@foo' B
    if [ "$mode" = thaw-set ]; then
      check 'set 실패 후 나머지 옵션 진행' pane_value_is "$first" '@after' C
      check '중복 옵션의 마지막 성공값 유지' pane_value_is "$first" '@foo' A
      check '실패한 set 옵션 없음' pane_option_absent "$first" '@fail'
    else
      check "${mode} 기존 값 유지" pane_value_is "$first" '@foo' OLD
      check "${mode} stale 값 유지" pane_value_is "$first" '@stale' OLD
      check "${mode} 실패 후 set 호출 없음" fails awk -F '\t' -v pane="$first" '$1 == "-p" && $2 == pane {found=1} END {exit !found}' "$GLACIER_TRACE"
      if [ "$mode" = thaw-list ]; then
        check '목록 실패 후 unset 호출 없음' fails grep -Fq "$first" "$GLACIER_TRACE"
      else
        check 'unset 실패 후 추가 unset 없음' test "$(awk -F '\t' -v pane="$first" '$1 == "-up" && $2 == pane {n++} END {print n+0}' "$GLACIER_TRACE")" -eq 1
      fi
    fi
    check "${mode} 값·원본 진단 로그 누출 없음" fails grep -Eq 'no-log-secret|노출금지진단' "$freeze_test_dir/saves/"*.log "$freeze_test_dir/thaw-output"
  done
  check '명령 실패에서 완전 성공 로그 없음' fails grep -q 'thaw complete' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_thaw_special_bytes() {
  freeze_test_setup || return 1
  local first name value escaped_name escaped_value i
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  # tmux 3.0의 기존 단일 pane 레이아웃 결함을 피하도록 두 pane으로 검증한다.
  tmux split-window -d -t "$first" 'sleep 60' || return 1
  value=$'한글\t"따옴표"\\역슬래시\n중간\n\n'
  for ((i=0; i<240; i++)); do value="${value}x"; done
  value="${value}"$'\n\n'
  for name in '@' '@a b' $'@탭\t이름' $'@개행\n끝\n' '@"따옴표' '@#{pane_id}' '@semi;' '@back\;'; do
    prepare_tmux_option_name "$name" escaped_name
    tmux -u set-option -p -t "$first" "$escaped_name" "$value" || return 1
  done
  for i in 0 1 2 3; do
    escaped_value=';'
    while [ "${#escaped_value}" -le "$i" ]; do escaped_value="\\${escaped_value}"; done
    escape_tmux_argument "$escaped_value" escaped_value
    tmux -u set-option -p -t "$first" "@end$i" "$escaped_value" || return 1
  done
  tmux -u set-option -p -t "$first" '@literal' '#{pane_id}' || return 1
  run_real_freeze || return 1
  for name in '@' '@a b' $'@탭\t이름' $'@개행\n끝\n' '@"따옴표' '@#{pane_id}' '@semi;' '@back\;'; do
    prepare_tmux_option_name "$name" escaped_name
    tmux -u set-option -p -t "$first" "$escaped_name" OLD || return 1
  done
  for i in 0 1 2 3; do tmux -u set-option -p -t "$first" "@end$i" OLD || return 1; done
  tmux -u set-option -p -t "$first" '@literal' OLD || return 1
  check '특수 이름·값 Thaw 성공' run_real_thaw
  for name in '@' '@a b' $'@탭\t이름' $'@개행\n끝\n' '@"따옴표' '@#{pane_id}' '@semi;' '@back\;'; do
    check '특수 이름과 긴 한글·탭·끝 개행 복원' pane_value_is "$first" "$name" "$value"
  done
  check '단독 세미콜론 값 복원' pane_value_is "$first" '@end0' ';'
  check '역슬래시 하나와 끝 세미콜론 복원' pane_value_is "$first" '@end1' '\;'
  check '역슬래시 둘과 끝 세미콜론 복원' pane_value_is "$first" '@end2' '\\;'
  check '역슬래시 셋과 끝 세미콜론 복원' pane_value_is "$first" '@end3' '\\\;'
  check '값의 format 문법 바이트 보존' pane_value_is "$first" '@literal' '#{pane_id}'
  freeze_test_cleanup
}

pane_value_matches_file() {
  local actual
  capture_option_value "$1" "$2" actual || return 1
  printf '%s' "$actual" >"$freeze_test_dir/actual-value" || return 1
  cmp -s "$3" "$freeze_test_dir/actual-value"
}

test_server_restart_round_trip() {
  freeze_test_setup || return 1
  local first second third value long_value special_name prepared_name prepared_value snapshot
  tmux -u set-option -g base-index 3 || return 1
  tmux -u set-option -g pane-base-index 2 || return 1
  tmux new-window -d -t freeze-options:3 'sleep 60' || return 1
  tmux kill-window -t freeze-options:0 || return 1
  first="$(tmux list-panes -t freeze-options:3 -F '#{pane_id}')" || return 1
  second="$(tmux split-window -d -P -F '#{pane_id}' -t "$first" 'sleep 60')" || return 1
  third="$(tmux split-window -d -P -F '#{pane_id}' -t "$second" 'sleep 60')" || return 1
  tmux -u set-option -g '@shared' global || return 1
  tmux -u set-option -w -t freeze-options:3 '@shared' window || return 1
  tmux -u set-option -p -t "$first" '@project' ninetoten || return 1
  tmux -u set-option -p -t "$first" '@empty' '' || return 1
  tmux -u set-option -p -t "$first" '@shared' local || return 1
  special_name='@#{pane_id};'
  value=$'한글\t"따옴표"\\역슬래시\n중간\n\n'
  prepare_tmux_option_name "$special_name" prepared_name
  tmux -u set-option -p -t "$first" "$prepared_name" "$value" || return 1
  printf '%s' "$value" >"$freeze_test_dir/expected-special" || return 1
  long_value='긴 값'
  while [ "${#long_value}" -lt 260 ]; do long_value="${long_value}x"; done
  printf '%s' "$long_value" >"$freeze_test_dir/expected-long" || return 1
  tmux -u set-option -p -t "$first" '@long' "$long_value" || return 1
  tmux -u set-option -p -t "$third" '@worktree' feat-order || return 1
  escape_tmux_argument '\;' prepared_value
  tmux -u set-option -p -t "$third" '@semi\;' "$prepared_value" || return 1

  check_required '세 pane 실제 Freeze 성공' run_real_freeze || return 1
  snapshot="$freeze_test_dir/saves/last"
  check '세 pane의 마커가 스냅샷에 있음' test "$(awk -F '\t' '$1 == "pane_user_options" {n++} END {print n+0}' "$snapshot")" -eq 3
  check '옵션 없는 pane도 마커를 가짐' awk -F '\t' '$1 == "pane_user_options" && $2 == "freeze-options" && $3 == 3 && $4 == 3 {found=1} END {exit !found}' "$snapshot"
  check '긴 값 레코드가 한 줄로 저장됨' awk -F '\t' '$1 == "pane_user_option" && $5 == "b64:QGxvbmc=" {found=(NF == 6 && length($6) > 300)} END {exit !found}' "$snapshot"

  tmux kill-server || return 1
  GLACIER_TEST_SOCKET="$freeze_test_dir/socket-restored"
  TMUX="$GLACIER_TEST_SOCKET,1,0"
  export GLACIER_TEST_SOCKET TMUX
  tmux -f /dev/null new-session -d -s seed 'sleep 60' || return 1
  tmux -u set-option -g '@frost-dir' "$freeze_test_dir/saves" || return 1
  tmux -u set-option -g base-index 3 || return 1
  tmux -u set-option -g pane-base-index 2 || return 1
  check_required '새 서버에서 실제 Thaw 성공' run_real_thaw || return 1
  first="$(tmux display-message -p -t freeze-options:3.2 '#{pane_id}')" || return 1
  second="$(tmux display-message -p -t freeze-options:3.3 '#{pane_id}')" || return 1
  third="$(tmux display-message -p -t freeze-options:3.4 '#{pane_id}')" || return 1
  check '재생성된 세 pane 수' test "$(tmux list-panes -t freeze-options:3 -F '#{pane_id}' | wc -l | tr -d ' ')" -eq 3
  check '첫 pane의 프로젝트 옵션 복원' pane_value_is "$first" '@project' ninetoten
  check '빈 값은 설정된 상태로 복원' pane_value_is "$first" '@empty' ''
  check '빈 값은 unset과 다름' tmux -u show-options -p -t "$first" '@empty'
  check '상위 scope와 동일한 local 이름 복원' pane_value_is "$first" '@shared' local
  check '중간·끝 개행을 파일 바이트로 비교' pane_value_matches_file "$first" "$special_name" "$freeze_test_dir/expected-special"
  check '긴 값을 파일 바이트로 비교' pane_value_matches_file "$first" '@long' "$freeze_test_dir/expected-long"
  check '빈 집합 pane에 local 옵션이 없음' pane_option_absent "$second" '@shared'
  check '세 번째 pane의 옵션 복원' pane_value_is "$third" '@worktree' feat-order
  check '끝 세미콜론 이름과 값 복원' pane_value_is "$third" '@semi;' '\;'

  tmux -u set-option -p -t "$first" '@project' OLD || return 1
  tmux -u set-option -p -t "$first" '@stale' OLD || return 1
  tmux -u set-option -p -t "$second" '@stale' OLD || return 1
  check_required '기존 pane 위 반복 Thaw 성공' run_real_thaw || return 1
  check '반복 Thaw가 스냅샷 값을 복구' pane_value_is "$first" '@project' ninetoten
  check '반복 Thaw가 stale 옵션을 제거' pane_option_absent "$first" '@stale'
  check '빈 집합 pane에서도 stale 옵션 제거' pane_option_absent "$second" '@stale'
  check '반복 Thaw가 pane 수를 유지' test "$(tmux list-panes -t freeze-options:3 -F '#{pane_id}' | wc -l | tr -d ' ')" -eq 3
  freeze_test_cleanup
}

test_colliding_name_sets_and_long_name() {
  freeze_test_setup || return 1
  local first second long_name colliding_name actual
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  second="$(tmux split-window -d -P -F '#{pane_id}' -t "$first" 'sleep 60')" || return 1
  colliding_name=$'@a one\n@b'
  tmux -u set-option -p -t "$first" "$colliding_name" two || return 1
  tmux -u set-option -p -t "$second" '@a' one || return 1
  tmux -u set-option -p -t "$second" '@b' two || return 1
  tmux -u show-options -p -t "$first" >"$freeze_test_dir/list-one" || return 1
  tmux -u show-options -p -t "$second" >"$freeze_test_dir/list-two" || return 1
  check '서로 다른 이름 집합의 나열 문자열 충돌' same_file "$freeze_test_dir/list-one" "$freeze_test_dir/list-two"
  actual="$(printf '%s' "$colliding_name" | encode_base64)" || return 1
  printf 'b64:%s\n' "$actual" >"$freeze_test_dir/expected-one"
  printf 'b64:QGE=\nb64:QGI=\n' >"$freeze_test_dir/expected-two"
  check '충돌 목록의 첫 집합은 이름 하나' list_pane_user_option_names "$first" >"$freeze_test_dir/actual-one"
  check '첫 이름 집합의 정확한 열거' same_file "$freeze_test_dir/expected-one" "$freeze_test_dir/actual-one"
  check '충돌 목록의 둘째 집합은 이름 둘' list_pane_user_option_names "$second" >"$freeze_test_dir/actual-two"
  check '둘째 이름 집합의 정확한 열거' same_file "$freeze_test_dir/expected-two" "$freeze_test_dir/actual-two"
  long_name="$colliding_name"
  while [ "${#long_name}" -lt 245 ]; do long_name="${long_name}x"; done
  tmux -u set-option -p -t "$second" "$long_name" LONG || return 1
  actual="$(printf '%s' "$long_name" | encode_base64)" || return 1
  printf 'b64:QGE=\nb64:%s\nb64:QGI=\n' "$actual" >"$freeze_test_dir/expected-two"
  check '증가 순서가 필요한 긴 이름 열거' list_pane_user_option_names "$second" >"$freeze_test_dir/actual-two"
  check '긴 이름과 짧은 접두 이름을 모두 구별' same_file "$freeze_test_dir/expected-two" "$freeze_test_dir/actual-two"
  freeze_test_cleanup
}

test_name_listing_partial_failure() {
  local mode output_dir
  output_dir="$(mktemp -d "${TMPDIR:-/tmp}/glacier-partial.XXXXXX")" || return 1
  tmux() {
    if [ "$#" -eq 5 ]; then
      printf '@a one\n@b two\n'
      [ "$mode" != list ]
      return $?
    fi
    case "${6:-}" in
      @a) printf '@a one\n' ;;
      @b) printf '@b two\n'; return 47 ;;
      *) return 1 ;;
    esac
  }
  mode=list
  check '전체 목록의 부분 출력 후 실패 전파' fails list_pane_user_option_names '%1' >"$output_dir/output"
  check '전체 목록 실패의 부분 출력 폐기' is_empty "$output_dir/output"
  mode=query
  check '이름 질의의 부분 출력 후 실패 전파' fails list_pane_user_option_names '%1' >"$output_dir/output"
  check '이름 질의 실패의 부분 출력 폐기' is_empty "$output_dir/output"
  rm -rf "$output_dir"
  unset -f tmux
}


test_orphan_missing_pane_warn_success() {
  freeze_test_setup || return 1
  local first second
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@keep' LIVE || return 1
  write_thaw_snapshot <<EOF || return 1
pane_user_options	freeze-options	0	0
pane_user_option	freeze-options	0	0	b64:QGtlZXA=	b64:T0s=
pane_user_options	freeze-options	0	99
pane_user_option	freeze-options	0	99	b64:QG1pc3M=	b64:WFRU
EOF
  check '고아 pane thaw 성공' run_real_thaw
  check '고아 pane WARN 기록' grep -q '고아 thaw' "$freeze_test_dir/saves/"*.log
  check '유효 pane 옵션 복원' pane_value_is "$first" '@keep' OK
  freeze_test_cleanup
}

test_frost_version_write_and_compat() {
  freeze_test_setup || return 1
  local first snapshot
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@ver' V2 || return 1
  check 'Freeze 성공(version 2)' run_real_freeze
  snapshot="$(resolve_symlink "$freeze_test_dir/saves/last")"
  check '새 스냅샷 frost_version=2' test "$(head -1 "$snapshot")" = $'frost_version\t2'
  write_thaw_snapshot <<EOF || return 1
pane_user_options	freeze-options	0	0
pane_user_option	freeze-options	0	0	b64:QHZlcg==	b64:VjE=
EOF
  # write_thaw_snapshot writes frost_version 1 header
  check 'version 1 thaw 성공' run_real_thaw
  check 'version 1 옵션 복원' pane_value_is "$first" '@ver' V1
  printf 'frost_version\t3\n' >"$freeze_test_dir/saves/manual.txt"
  ln -sf manual.txt "$freeze_test_dir/saves/last"
  check '알 수 없는 version 거부' fails run_real_thaw
  check '지원하지 않는 버전 로그' grep -q 'unsupported frost_version' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_frost_dir_guard_and_readonly_migrate() {
  freeze_test_setup || return 1
  local ro fallback marker
  ro="$freeze_test_dir/readonly-saves"
  fallback="$freeze_test_dir/fallback-saves"
  mkdir -p "$ro" "$fallback" || return 1
  printf 'frost_version\t1\npane\tdemo\t0\t1\t0\ttitle\t:/tmp\t1\n' >"$ro/frost_old.txt"
  ln -s frost_old.txt "$ro/last"
  chmod a-w "$ro" || return 1

  local saved_default saved_cache
  saved_default="$default_frost_dir"
  saved_cache="$default_frost_cache_dir"
  _frost_dir_cache=""
  _frost_dir_cache_key=""
  default_frost_dir="$fallback"
  default_frost_cache_dir="$freeze_test_dir/cache-saves"
  tmux -u set-option -g '@frost-dir' "$ro" || return 1

  check '읽기 전용 경로에서 frost_dir fallback' test "$(frost_dir)" = "$fallback"
  marker="$fallback/.frost-migrated-from"
  check 'one-shot migrate 마커' test -f "$marker"
  check '원본 save 보존' test -f "$ro/frost_old.txt"
  check '대상 save 복사' test -f "$fallback/frost_old.txt"
  check '대상 last 링크' test -L "$fallback/last"

  _frost_dir_cache=""
  _frost_dir_cache_key=""
  check '빈 @frost-dir 거부' fails validate_frost_dir_setting ""
  check '루트 @frost-dir 거부' fails validate_frost_dir_setting "/"
  check '상대 @frost-dir 거부' fails validate_frost_dir_setting "relative/path"
  default_frost_dir="$saved_default"
  default_frost_cache_dir="$saved_cache"
  chmod u+w "$ro" 2>/dev/null || true
  freeze_test_cleanup
}

test_freeze_empty_line_guard() {
  freeze_test_setup || return 1
  local first snapshot
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@ok' 1 || return 1
  # Real freeze already receives trailing blank lines from here-strings; success locks the guard.
  check '빈 줄이 있어도 Freeze 성공' run_real_freeze
  snapshot="$(resolve_symlink "$freeze_test_dir/saves/last")"
  check '빈 줄 가드 후 스냅샷 존재' test -f "$snapshot"
  check '빈 줄 가드 후 옵션 기록' grep -q $'pane_user_option\t' "$snapshot"
  freeze_test_cleanup
}

if [ "$#" -gt 0 ]; then
  for test_function in "$@"; do
    run_freeze_test "$test_function" "$test_function"
  done
else
  test_codec_bytes
  test_decoder_portability
  test_capture_failure
  test_argument_and_names
  test_real_tmux_names
  run_freeze_test 'Freeze 레코드' test_freeze_records
  run_freeze_test 'Freeze 범위' test_freeze_scope
  run_freeze_test 'Freeze 실패 보존' test_freeze_failure_keeps_last
  run_freeze_test 'Thaw 교체' test_replace_and_empty_marker
  run_freeze_test 'Thaw 구형과 orphan' test_legacy_and_orphan
  run_freeze_test '고아 pane WARN 성공' test_orphan_missing_pane_warn_success
  run_freeze_test 'frost_version 호환' test_frost_version_write_and_compat
  run_freeze_test 'frost-dir guard와 migrate' test_frost_dir_guard_and_readonly_migrate
  run_freeze_test 'Freeze 빈 줄 가드' test_freeze_empty_line_guard
  run_freeze_test 'Thaw 손상 격리' test_corrupt_pane_isolation
  run_freeze_test 'Thaw 손상 마커 격리' test_corrupt_marker_isolation
  run_freeze_test 'Thaw 정확한 대상' test_exact_targets_and_duplicates
  run_freeze_test 'Thaw 명령 실패' test_thaw_command_failures
  run_freeze_test 'Thaw 특수 바이트' test_thaw_special_bytes
  run_freeze_test '서버 재시작 왕복' test_server_restart_round_trip
  run_freeze_test '이름 목록 충돌과 긴 이름' test_colliding_name_sets_and_long_name
  test_name_listing_partial_failure
fi
printf '결과: %s개 통과, %s개 실패\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
