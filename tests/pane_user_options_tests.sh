#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/helpers.sh
source "$SCRIPT_DIR/../scripts/helpers.sh"

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
  freeze_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/glacier-freeze-test.XXXXXX")" || return 1
  mkdir -p "$freeze_test_dir/bin" "$freeze_test_dir/saves" || return 1
  GLACIER_REAL_TMUX="$(command -v tmux)"
  GLACIER_REAL_BASE64="$(command -v base64)"
  GLACIER_TEST_SOCKET="$freeze_test_dir/socket"
  GLACIER_TEST_DIR="$freeze_test_dir"
  export GLACIER_REAL_TMUX GLACIER_REAL_BASE64 GLACIER_TEST_SOCKET GLACIER_TEST_DIR
  cat >"$freeze_test_dir/bin/tmux" <<'EOF'
#!/bin/sh
case "${GLACIER_FAIL_MODE:-}" in
  query) case " $* " in *' show-options -pv '*) exit 37 ;; esac ;;
  dump) case " $* " in *' list-panes -a '*) exit 38 ;; esac ;;
esac
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
  unset GLACIER_FAIL_MODE GLACIER_REAL_TMUX GLACIER_REAL_BASE64 GLACIER_TEST_SOCKET GLACIER_TEST_DIR freeze_test_dir freeze_test_original_path
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

test_codec_bytes
test_decoder_portability
test_capture_failure
test_argument_and_names
test_real_tmux_names
run_freeze_test 'Freeze 레코드' test_freeze_records
run_freeze_test 'Freeze 범위' test_freeze_scope
run_freeze_test 'Freeze 실패 보존' test_freeze_failure_keeps_last
printf '결과: %s개 통과, %s개 실패\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
