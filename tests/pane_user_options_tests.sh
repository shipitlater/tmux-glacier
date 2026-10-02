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
    printf 'PASS: %s\n' "$description" >&2
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n' "$description" >&2
  fi
}

check_required() {
  local description="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$description" >&2
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n' "$description" >&2
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
  check 'Encode empty bytes as one line' encode_base64 <"$source_file" >"$encoded_file"
  check 'Empty Base64 payload' is_empty "$encoded_file"
  field_value=unchanged
  check 'Decode empty b64 value' decode_option_field 'b64:' field_value
  check 'Restore empty value exactly' test -z "$field_value"
  check 'Preserve field decoder selection in parent shell' test -n "${BASE64_DECODER_FLAG:-}"

  printf '한글\t"따옴표"\\역슬래시\n중간\n\n' >"$source_file"
  i=0
  while [ "$i" -lt 240 ]; do printf 'x' >>"$source_file"; i=$((i + 1)); done
  printf '\n\n' >>"$source_file"
  check 'Encode long mixed bytes' encode_base64 <"$source_file" >"$encoded_file"
  check 'Keep long Base64 on one line' test "$(wc -l <"$encoded_file" | tr -d ' ')" -eq 0
  check 'Decode long mixed bytes' decode_base64 <"$encoded_file" >"$decoded_file"
  check 'Match long mixed bytes' same_file "$source_file" "$decoded_file"
  field_value=unchanged
  check 'Preserve trailing newline in field' decode_option_field "b64:$(cat "$encoded_file")" field_value
  printf '%s' "$field_value" >"$decoded_file"
  check 'Match field bytes' same_file "$source_file" "$decoded_file"
  check 'Reject field without prefix' fails decode_option_field 'QQ==' field_value

  for bad in 'A' 'QQ=' 'QQ===' 'Q=Q=' 'QQ==A' 'Q?==' 'Q Q=' $'QQ==\n'; do
    printf '%s' "$bad" >"$encoded_file"
    check 'Reject invalid Base64' fails decode_base64 <"$encoded_file" >"$decoded_file"
    check 'Suppress partial invalid Base64 output' is_empty "$decoded_file"
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
  check 'Select BSD decoder' init_base64_decoder
  check 'BSD decoder flag' test "${BASE64_DECODER_FLAG:-}" = -D
  check 'Use BSD decoder' decode_base64 <"$encoded_file" >"$decoded_file"
  check 'BSD decoding result' test "$(cat "$decoded_file")" = ABC
  decoder_mode=gnu
  unset BASE64_DECODER_FLAG
  check 'Select GNU decoder' init_base64_decoder
  check 'GNU decoder flag' test "${BASE64_DECODER_FLAG:-}" = -d
  decoder_mode=broken
  check 'Propagate decoder failure after partial output' fails decode_base64 <"$encoded_file" >"$decoded_file"
  check 'Discard failed decoder output' is_empty "$decoded_file"
  unset -f base64
  unset BASE64_DECODER_FLAG
  base64() { printf 'QUJD'; return 38; }
  check 'Propagate encoder failure' fails encode_base64 <"$encoded_file" >"$decoded_file"
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
  check 'Propagate lookup failure status' fails capture_option_value '%1' '@missing' captured
  check 'Preserve output variable on lookup failure' test "$captured" = unchanged
  check 'Reject lookup without output terminator' fails capture_option_value '%1' '@gone' captured
  check 'Look up empty value' capture_option_value '%1' '@empty' captured
  check 'Preserve empty value' test -z "$captured"
  check 'Look up two trailing newlines' capture_option_value '%1' '@multi' captured
  printf '%s' "$captured" >"$output_file"
  check 'Preserve two trailing newlines' test "$(od -An -tx1 "$output_file" | tr -d ' \n')" = 'ed959ceab8800aeb819d0a0a'
  unset -f tmux
  rm -f "$output_file"
}

test_argument_and_names() {
  local value expected_file actual_file
  escape_tmux_argument 'x\\;' value
  check 'Protect trailing semicolon' test "$value" = 'x\\\;'
  escape_tmux_argument 'a;b' value
  check 'Preserve embedded semicolon' test "$value" = 'a;b'
  prepare_tmux_option_name '@#;name;' value
  check 'Protect # in name and trailing semicolon' test "$value" = '@##;name\;'

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
  check 'Enumerate candidate boundaries for names with spaces/newlines' list_pane_user_option_names '%1' >"$actual_file"
  check 'Return names only as Base64' same_file "$expected_file" "$actual_file"
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
    printf 'FAIL: start isolated tmux server\n' >&2
    failed=$((failed + 1))
    unset -f tmux
    rm -f "$expected_file" "$actual_file" "$socket"
    return
  fi
  pane_id="$(tmux list-panes -t pane-options -F '#{pane_id}')"
  if [ -z "$pane_id" ]; then
    printf 'FAIL: query pane on isolated tmux server\n' >&2
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
  check 'Enumerate special local names in real tmux' list_pane_user_option_names "$pane_id" >"$actual_file"
  check 'Exclude parent scopes and built-ins in real tmux' same_file "$expected_file" "$actual_file"
  captured=unchanged
  check 'Look up newline value in real tmux' capture_option_value "$pane_id" $'@c\n#d' captured
  printf '%s' "$captured" >"$actual_file"
  printf '한글\n끝\n\n' >"$expected_file"
  check 'Preserve trailing newline in real tmux' same_file "$expected_file" "$actual_file"
  captured=unchanged
  check 'Look up trailing-semicolon name in real tmux' capture_option_value "$pane_id" '@semi;' captured
  check 'Preserve trailing-semicolon value in real tmux' test "$captured" = '세미콜론;'
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
          thaw-unset:-up:*) printf 'hidden-diagnostic\n' >&2; exit 41 ;;
          thaw-set:-p:@foo) [ "${7:-}" != B ] || exit 43 ;;
          thaw-set:-p:@fail) printf 'hidden-diagnostic\n' >&2; exit 42 ;;
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
  check 'Real Freeze save succeeds' run_real_freeze
  snapshot="$freeze_test_dir/saves/last"
  check 'Record markers for two panes' test "$(awk -F '\t' '$1 == "pane_user_options" {n++} END {print n+0}' "$snapshot")" -eq 2
  check 'Record marker for pane without options' test "$(awk -F '\t' '$1 == "pane_user_options" && $4 == 1 {n++} END {print n+0}' "$snapshot")" -eq 1
  check 'Markers have 4 fields and options 6 fields' awk -F '\t' '$1 == "pane_user_options" && NF != 4 {exit 1} $1 == "pane_user_option" && NF != 6 {exit 1}' "$snapshot"
  check 'Base64 option linked to pane identifier' awk -F '\t' '$1 == "pane_user_option" {if ($2 == "freeze-options" && $3 == 0 && $4 == 0 && $5 == "b64:QHByb2plY3Q=" && $6 == "b64:bmluZXRvdGVu") n++} END {exit !(n == 1)}' "$snapshot"
  check 'Compare repeated save contents' run_real_freeze
  check 'Keep one file across repeated saves' test "$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')" -eq 1
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
  check 'Separate scope save succeeds' run_real_freeze
  snapshot="$freeze_test_dir/saves/last"
  check 'Save only one local option' test "$(awk -F '\t' '$1 == "pane_user_option" {n++} END {print n+0}' "$snapshot")" -eq 1
  check 'Exclude parent scopes and built-ins' awk -F '\t' '$1 == "pane_user_option" {exit !($5 == "b64:QGxvY2Fs" && $6 == "b64:bG9jYWw=")}' "$snapshot"
  freeze_test_cleanup
}

test_freeze_failure_keeps_last() {
  freeze_test_setup || return 1
  local pane snapshot old_target mode old_log_count
  pane="$(tmux list-panes -t freeze-options -F '#{pane_id}')"
  tmux -u set-option -p -t "$pane" '@fault' before || return 1
  check 'Baseline Freeze save succeeds' run_real_freeze
  snapshot="$freeze_test_dir/saves/last"
  old_target="$(readlink "$snapshot")"
  cp "$snapshot" "$freeze_test_dir/original" || return 1
  tmux -u set-option -p -t "$pane" '@fault' after || return 1
  old_log_count="$(grep -c 'freeze complete' "$freeze_test_dir/saves"/*.log || true)"
  for mode in query encode write dump; do
    GLACIER_FAIL_MODE="$mode"
    export GLACIER_FAIL_MODE
    check "${mode} failure propagation" fails run_real_freeze
    check "${mode} preserve target bytes after failure" same_file "$snapshot" "$freeze_test_dir/original"
    check "${mode} preserve last after failure" test "$(readlink "$snapshot")" = "$old_target"
    check "${mode} no success log after failure" test "$(grep -c 'freeze complete' "$freeze_test_dir/saves"/*.log || true)" = "$old_log_count"
    unset GLACIER_FAIL_MODE
  done
  check 'Clean up failed temporary snapshot' test "$(find "$freeze_test_dir/saves" -name '.frost-*' | wc -l | tr -d ' ')" -eq 0
  check 'Save succeeds after same-second change' run_real_freeze
  check 'Publish new file after same-second change' test "$(readlink "$snapshot")" != "$old_target"
  check 'Preserve previous file after same-second change' same_file "$freeze_test_dir/saves/$old_target" "$freeze_test_dir/original"
  freeze_test_cleanup
}

run_freeze_test() {
  local description="$1"
  shift
  if ! "$@"; then
    failed=$((failed + 1))
    printf 'FAIL: prepare or run %s\n' "$description" >&2
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
  check 'Real Thaw replacement succeeds' run_real_thaw
  check 'Restore @foo snapshot value' pane_value_is "$first" '@foo' A
  check 'Remove stale @bar' pane_option_absent "$first" '@bar'
  check 'Remove all local options for empty marker' pane_option_absent "$second" '@stale'
  check 'Preserve built-in' test "$(tmux show-options -pv -t "$first" remain-on-exit)" = on
  check 'Preserve global' test "$(tmux show-options -gv '@global-only')" = global
  check 'Preserve window' test "$(tmux show-options -wv -t freeze-options:0 '@window-only')" = window
  tmux -u set-option -p -t "$first" '@bar' again || return 1
  check 'Repeated Thaw succeeds' run_real_thaw
  check 'Repeated Thaw removes stale options' pane_option_absent "$first" '@bar'
  check 'Repeated Thaw preserves pane count' test "$(tmux list-panes -t freeze-options | wc -l | tr -d ' ')" -eq 2
  freeze_test_cleanup
}

test_legacy_and_orphan() {
  freeze_test_setup || return 1
  local first
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@foo' OLD || return 1
  write_thaw_snapshot </dev/null || return 1
  check 'Legacy snapshot Thaw succeeds' run_real_thaw
  check 'Preserve legacy snapshot local option' pane_value_is "$first" '@foo' OLD
  printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n' | write_thaw_snapshot || return 1
  run_real_thaw || true
  check 'Ignore orphan option' pane_value_is "$first" '@foo' OLD
  check 'Record orphan log' grep -q 'marker' "$freeze_test_dir/saves/"*.log
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
    check 'Corrupt record causes Thaw failure' fails run_real_thaw
    check 'Preserve existing options on corrupt pane' pane_value_is "$first" '@foo' OLD
    check 'Continue restoring other healthy pane' pane_value_is "$second" '@foo' B
    check 'No unset/set calls for corrupt pane' fails grep -Fq "$first" "$GLACIER_TRACE"
  done
  check 'No partial restore success log' fails grep -q 'thaw complete' "$freeze_test_dir/saves/"*.log
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
      check 'Corrupt marker diagnostic causes failure' fails run_real_thaw
      check 'Restore valid options with corrupt and valid markers' pane_value_is "$first" '@foo' A
      check 'Corrupt marker does not block normal replacement' pane_option_absent "$first" '@stale'
      check 'Record corrupt marker diagnostic' grep -q 'marker validation failed' "$freeze_test_dir/saves/"*.log
    done
    tmux -u set-option -p -t "$first" '@foo' OLD || return 1
    printf '%s\n' "$malformed" | write_thaw_snapshot || return 1
    check 'Missing valid marker causes failure' fails run_real_thaw
    check 'Preserve existing options without valid marker' pane_value_is "$first" '@foo' OLD
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
    check 'Orphan target pane WARN succeeds' run_real_thaw
    check 'Record orphan Thaw WARN' grep -q 'orphan thaw' "$freeze_test_dir/saves/"*.log
    check 'Orphan Thaw preserves existing options' pane_value_is "$first" '@foo' OLD
    check 'No unset/set calls for orphan target' is_empty "$GLACIER_TRACE"
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
    check 'Invalid identifier causes failure' fails run_real_thaw
    check 'No similar-session/current-pane fallback' pane_value_is "$first" '@foo' OLD
    check 'No unset/set calls for invalid target' is_empty "$GLACIER_TRACE"
  done
  {
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:QQ==\n'
    printf 'pane_user_options\tfreeze-options\t0\t0\n'
    printf 'pane_user_options\tfreeze-options\t0\t0\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:Qg==\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGVtcHR5\tb64:\n'
  } | write_thaw_snapshot || return 1
  : >"$GLACIER_TRACE"
  check 'Restore with duplicate markers and reversed records' run_real_thaw
  check 'Apply last value for duplicate name' pane_value_is "$first" '@foo' B
  check 'Distinguish empty value from unset' pane_value_is "$first" '@empty' ''
  check 'Duplicate markers still delete existing options once' test "$(awk -F '\t' '$1 == "-up" {n++} END {print n+0}' "$GLACIER_TRACE")" -eq 1
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
    check "${mode} failure status propagation" fails run_real_thaw
    unset GLACIER_FAIL_MODE
    check "${mode} continue restoring other pane" pane_value_is "$second" '@foo' B
    if [ "$mode" = thaw-set ]; then
      check 'Continue remaining options after set failure' pane_value_is "$first" '@after' C
      check 'Keep last successful value for duplicate option' pane_value_is "$first" '@foo' A
      check 'No failed set option' pane_option_absent "$first" '@fail'
    else
      check "${mode} preserve existing value" pane_value_is "$first" '@foo' OLD
      check "${mode} preserve stale value" pane_value_is "$first" '@stale' OLD
      check "${mode} no set calls after failure" fails awk -F '\t' -v pane="$first" '$1 == "-p" && $2 == pane {found=1} END {exit !found}' "$GLACIER_TRACE"
      if [ "$mode" = thaw-list ]; then
        check 'No unset calls after list failure' fails grep -Fq "$first" "$GLACIER_TRACE"
      else
        check 'No extra unset after unset failure' test "$(awk -F '\t' -v pane="$first" '$1 == "-up" && $2 == pane {n++} END {print n+0}' "$GLACIER_TRACE")" -eq 1
      fi
    fi
    check "${mode} no value/source diagnostic log leak" fails grep -Eq 'no-log-secret|hidden-diagnostic' "$freeze_test_dir/saves/"*.log "$freeze_test_dir/thaw-output"
  done
  check 'No complete success log on command failure' fails grep -q 'thaw complete' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_thaw_special_bytes() {
  freeze_test_setup || return 1
  local first name value escaped_name escaped_value i
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  # Test with two panes to avoid the existing single-pane layout bug in tmux 3.0.
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
  check 'Special names/values Thaw succeeds' run_real_thaw
  for name in '@' '@a b' $'@탭\t이름' $'@개행\n끝\n' '@"따옴표' '@#{pane_id}' '@semi;' '@back\;'; do
    check 'Restore special names and long Korean/tab/trailing-newline value' pane_value_is "$first" "$name" "$value"
  done
  check 'Restore standalone semicolon value' pane_value_is "$first" '@end0' ';'
  check 'Restore one backslash and trailing semicolon' pane_value_is "$first" '@end1' '\;'
  check 'Restore two backslashes and trailing semicolon' pane_value_is "$first" '@end2' '\\;'
  check 'Restore three backslashes and trailing semicolon' pane_value_is "$first" '@end3' '\\\;'
  check 'Preserve format syntax bytes in value' pane_value_is "$first" '@literal' '#{pane_id}'
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

  check_required 'Real Freeze succeeds for three panes' run_real_freeze || return 1
  snapshot="$freeze_test_dir/saves/last"
  check 'Snapshot contains markers for three panes' test "$(awk -F '\t' '$1 == "pane_user_options" {n++} END {print n+0}' "$snapshot")" -eq 3
  check 'Pane without options also has a marker' awk -F '\t' '$1 == "pane_user_options" && $2 == "freeze-options" && $3 == 3 && $4 == 3 {found=1} END {exit !found}' "$snapshot"
  check 'Long value record is stored on one line' awk -F '\t' '$1 == "pane_user_option" && $5 == "b64:QGxvbmc=" {found=(NF == 6 && length($6) > 300)} END {exit !found}' "$snapshot"

  tmux kill-server || return 1
  GLACIER_TEST_SOCKET="$freeze_test_dir/socket-restored"
  TMUX="$GLACIER_TEST_SOCKET,1,0"
  export GLACIER_TEST_SOCKET TMUX
  tmux -f /dev/null new-session -d -s seed 'sleep 60' || return 1
  tmux -u set-option -g '@frost-dir' "$freeze_test_dir/saves" || return 1
  tmux -u set-option -g base-index 3 || return 1
  tmux -u set-option -g pane-base-index 2 || return 1
  check_required 'Real Thaw succeeds on new server' run_real_thaw || return 1
  first="$(tmux display-message -p -t freeze-options:3.2 '#{pane_id}')" || return 1
  second="$(tmux display-message -p -t freeze-options:3.3 '#{pane_id}')" || return 1
  third="$(tmux display-message -p -t freeze-options:3.4 '#{pane_id}')" || return 1
  check 'Recreated pane count is three' test "$(tmux list-panes -t freeze-options:3 -F '#{pane_id}' | wc -l | tr -d ' ')" -eq 3
  check 'Restore first pane project option' pane_value_is "$first" '@project' ninetoten
  check 'Restore empty value as set' pane_value_is "$first" '@empty' ''
  check 'Empty value differs from unset' tmux -u show-options -p -t "$first" '@empty'
  check 'Restore local name matching parent scope' pane_value_is "$first" '@shared' local
  check 'Compare embedded/trailing newlines as file bytes' pane_value_matches_file "$first" "$special_name" "$freeze_test_dir/expected-special"
  check 'Compare long value as file bytes' pane_value_matches_file "$first" '@long' "$freeze_test_dir/expected-long"
  check 'Empty-set pane has no local option' pane_option_absent "$second" '@shared'
  check 'Restore third pane option' pane_value_is "$third" '@worktree' feat-order
  check 'Restore trailing-semicolon name and value' pane_value_is "$third" '@semi;' '\;'

  tmux -u set-option -p -t "$first" '@project' OLD || return 1
  tmux -u set-option -p -t "$first" '@stale' OLD || return 1
  tmux -u set-option -p -t "$second" '@stale' OLD || return 1
  check_required 'Repeated Thaw succeeds on existing panes' run_real_thaw || return 1
  check 'Repeated Thaw restores snapshot values' pane_value_is "$first" '@project' ninetoten
  check 'Repeated Thaw removes stale options' pane_option_absent "$first" '@stale'
  check 'Remove stale options from empty-set pane' pane_option_absent "$second" '@stale'
  check 'Repeated Thaw preserves pane count' test "$(tmux list-panes -t freeze-options:3 -F '#{pane_id}' | wc -l | tr -d ' ')" -eq 3
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
  check 'Listing strings collide for different name sets' same_file "$freeze_test_dir/list-one" "$freeze_test_dir/list-two"
  actual="$(printf '%s' "$colliding_name" | encode_base64)" || return 1
  printf 'b64:%s\n' "$actual" >"$freeze_test_dir/expected-one"
  printf 'b64:QGE=\nb64:QGI=\n' >"$freeze_test_dir/expected-two"
  check 'First colliding set has one name' list_pane_user_option_names "$first" >"$freeze_test_dir/actual-one"
  check 'Enumerate first name set exactly' same_file "$freeze_test_dir/expected-one" "$freeze_test_dir/actual-one"
  check 'Second colliding set has two names' list_pane_user_option_names "$second" >"$freeze_test_dir/actual-two"
  check 'Enumerate second name set exactly' same_file "$freeze_test_dir/expected-two" "$freeze_test_dir/actual-two"
  long_name="$colliding_name"
  while [ "${#long_name}" -lt 245 ]; do long_name="${long_name}x"; done
  tmux -u set-option -p -t "$second" "$long_name" LONG || return 1
  actual="$(printf '%s' "$long_name" | encode_base64)" || return 1
  printf 'b64:QGE=\nb64:%s\nb64:QGI=\n' "$actual" >"$freeze_test_dir/expected-two"
  check 'Enumerate long names requiring increasing order' list_pane_user_option_names "$second" >"$freeze_test_dir/actual-two"
  check 'Distinguish long and short prefix names' same_file "$freeze_test_dir/expected-two" "$freeze_test_dir/actual-two"
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
  check 'Propagate failure after partial full-list output' fails list_pane_user_option_names '%1' >"$output_dir/output"
  check 'Discard partial full-list output on failure' is_empty "$output_dir/output"
  mode=query
  check 'Propagate failure after partial name-query output' fails list_pane_user_option_names '%1' >"$output_dir/output"
  check 'Discard partial name-query output on failure' is_empty "$output_dir/output"
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
  check 'Orphan pane Thaw succeeds' run_real_thaw
  check 'Record orphan pane WARN' grep -q 'orphan thaw' "$freeze_test_dir/saves/"*.log
  check 'Restore valid pane option' pane_value_is "$first" '@keep' OK
  freeze_test_cleanup
}

test_frost_version_write_and_compat() {
  freeze_test_setup || return 1
  local first snapshot
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@ver' V2 || return 1
  check 'Freeze succeeds (version 2)' run_real_freeze
  snapshot="$(resolve_symlink "$freeze_test_dir/saves/last")"
  check 'New snapshot has frost_version=2' test "$(head -1 "$snapshot")" = $'frost_version\t2'
  write_thaw_snapshot <<EOF || return 1
pane_user_options	freeze-options	0	0
pane_user_option	freeze-options	0	0	b64:QHZlcg==	b64:VjE=
EOF
  # write_thaw_snapshot writes frost_version 1 header
  check 'Version 1 Thaw succeeds' run_real_thaw
  check 'Restore version 1 option' pane_value_is "$first" '@ver' V1
  printf 'frost_version\t3\n' >"$freeze_test_dir/saves/manual.txt"
  ln -sf manual.txt "$freeze_test_dir/saves/last"
  check 'Reject unknown version' fails run_real_thaw
  check 'Log unsupported version' grep -q 'unsupported frost_version' "$freeze_test_dir/saves/"*.log
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

  check 'frost_dir fallback on read-only path' test "$(frost_dir)" = "$fallback"
  marker="$fallback/.frost-migrated-from"
  check 'One-shot migrate marker' test -f "$marker"
  check 'Preserve original save' test -f "$ro/frost_old.txt"
  check 'Copy save to target' test -f "$fallback/frost_old.txt"
  check 'Target last link' test -L "$fallback/last"

  _frost_dir_cache=""
  _frost_dir_cache_key=""
  check 'Reject empty @frost-dir' fails validate_frost_dir_setting ""
  check 'Reject root @frost-dir' fails validate_frost_dir_setting "/"
  check 'Reject relative @frost-dir' fails validate_frost_dir_setting "relative/path"
  default_frost_dir="$saved_default"
  default_frost_cache_dir="$saved_cache"
  chmod u+w "$ro" 2>/dev/null || true
  freeze_test_cleanup
}

test_migration_selected_snapshot() {
  local link_type
  for link_type in relative absolute regular; do
    freeze_test_setup || return 1
    local pane ro snapshot fallback
    local XDG_DATA_HOME="$freeze_test_dir/data"
    local XDG_CACHE_HOME="$freeze_test_dir/cache"
    export XDG_DATA_HOME XDG_CACHE_HOME
    pane="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
    ro="$freeze_test_dir/readonly"
    fallback="$XDG_DATA_HOME/tmux/glacier"
    snapshot=frost_20261002T120000.txt
    mkdir -p "$ro" "$fallback" || return 1
    {
      printf 'frost_version\t2\npane_user_options\tfreeze-options\t0\t0\n'
      printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGtlZXA=\tb64:U09VUkNF\n'
    } >"$ro/$snapshot"
    {
      printf 'frost_version\t2\npane_user_options\tfreeze-options\t0\t0\n'
      printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGtlZXA=\tb64:T0xE\n'
    } >"$fallback/$snapshot"
    cp "$fallback/$snapshot" "$freeze_test_dir/previous-snapshot" || return 1
    ln -s "$snapshot" "$fallback/last" || return 1
    case "$link_type" in
      relative) ln -s "$snapshot" "$ro/last" ;;
      absolute) ln -s "$ro/$snapshot" "$ro/last" ;;
      regular) cp "$ro/$snapshot" "$ro/last" ;;
    esac
    chmod a-w "$ro" || return 1
    tmux set-option -g '@frost-dir' "$ro" || return 1
    tmux set-option -p -t "$pane" '@keep' LIVE || return 1

    check "Thaw succeeds after migrating $link_type last" run_real_thaw
    check "Restore source option selected by $link_type last" pane_value_is "$pane" '@keep' SOURCE
    check "Fallback matches source snapshot selected by $link_type last" same_file "$ro/last" "$fallback/last"
    check "Preserve existing snapshot with a name collision for $link_type last" same_file "$fallback/$snapshot" "$freeze_test_dir/previous-snapshot"
    check "Preserve source file for $link_type last" same_file "$ro/$snapshot" "$ro/last"

    tmux set-option -p -t "$pane" '@keep' AFTER || return 1
    check "Freeze to fallback succeeds after $link_type migration" run_real_freeze
    tmux set-option -p -t "$pane" '@keep' LIVE || return 1
    check "Thaw succeeds without repeating $link_type migration" run_real_thaw
    check "Preserve subsequent save in $link_type fallback" pane_value_is "$pane" '@keep' AFTER
    chmod u+w "$ro" || return 1
    freeze_test_cleanup
  done
}

test_migration_current_snapshot_retention() {
  freeze_test_setup || return 1
  local source_dir fallback snapshot i
  local XDG_DATA_HOME="$freeze_test_dir/data"
  export XDG_DATA_HOME
  source_dir="$freeze_test_dir/saves"
  fallback="$XDG_DATA_HOME/tmux/glacier"
  tmux set-window-option -t freeze-options:0 automatic-rename off || return 1
  tmux rename-window -t freeze-options:0 stable || return 1
  run_real_freeze || return 1
  snapshot="$(readlink "$source_dir/last")"
  touch -t 202001010000 "$source_dir/$snapshot" || return 1
  mkdir -p "$fallback" || return 1
  for i in 1 2 3 4 5 6; do
    printf 'frost_version\t1\n' >"$fallback/frost_other_$i.txt"
  done
  chmod a-w "$source_dir" || return 1
  check 'Migrate old source and skip duplicate freeze successfully' run_real_freeze
  check 'Duplicate freeze does not replace current last with a new file' test "$(readlink "$fallback/last")" = "$snapshot"
  check 'Preserve old current snapshot during backup cleanup' same_file "$source_dir/last" "$fallback/last"
  check 'Current last target exists' test -f "$fallback/last"
  chmod u+w "$source_dir" || return 1
  freeze_test_cleanup
}

test_migration_source_change() {
  freeze_test_setup || return 1
  local src fallback
  fallback="$freeze_test_dir/fallback"
  for src in first second; do
    mkdir -p "$freeze_test_dir/$src" || return 1
    printf '%s\n' "$src" >"$freeze_test_dir/$src/frost_saved.txt"
    ln -s frost_saved.txt "$freeze_test_dir/$src/last" || return 1
    check "Migrate $src source path successfully" migrate_frost_dir_once "$freeze_test_dir/$src" "$fallback"
    check "Select last from $src source path" same_file "$freeze_test_dir/$src/last" "$fallback/last"
  done
  freeze_test_cleanup
}

test_frost_dir_raw_validation() {
  freeze_test_setup || return 1
  local configured case_name plugin_dir
  local default_frost_dir="$freeze_test_dir/default"
  local default_frost_cache_dir="$freeze_test_dir/cache"
  local _frost_dir_cache='' _frost_dir_cache_key=''
  plugin_dir="$(cd "$SCRIPT_DIR/.." && pwd)"
  cat >"$freeze_test_dir/bin/setsid" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$GLACIER_TEST_DIR/launches"
EOF
  chmod +x "$freeze_test_dir/bin/setsid" || return 1
  tmux set-option -g '@frost-auto-restore' off || return 1
  tmux set-option -g '@frost-auto-save-interval' 60 || return 1

  for case_name in empty trailing-newline embedded-newline carriage-return embedded-carriage-return backslash-carriage-return relative root; do
    case "$case_name" in
      empty) configured='' ;;
      trailing-newline) configured="$freeze_test_dir/trailing"$'\n' ;;
      embedded-newline) configured="$freeze_test_dir/embedded"$'\n''path' ;;
      carriage-return) configured="$freeze_test_dir/carriage"$'\r' ;;
      embedded-carriage-return) configured="$freeze_test_dir/embedded"$'\r''path' ;;
      backslash-carriage-return) configured="$freeze_test_dir/backslash\\"$'\r' ;;
      relative) configured=relative/path ;;
      root) configured=/ ;;
    esac
    rm -f "$freeze_test_dir/launches" || return 1
    tmux set-option -g '@frost-dir' "$configured" || return 1
    check "Reject invalid raw @frost-dir ($case_name)" fails frost_dir >"$freeze_test_dir/dir-output" 2>"$freeze_test_dir/dir-errors"
    check "Freeze returns failure for invalid paths ($case_name)" fails run_real_freeze
    check "Thaw returns failure for invalid paths ($case_name)" fails run_real_thaw
    check "Plugin load returns failure for invalid paths ($case_name)" fails /bin/bash "$plugin_dir/glacier.tmux" >"$freeze_test_dir/plugin-output" 2>&1
    check "Prevent auto-save launch for invalid paths ($case_name)" test ! -e "$freeze_test_dir/launches"
    check "Invalid paths produce no directory output ($case_name)" is_empty "$freeze_test_dir/dir-output"
  done
  tmux set-option -g '@frost-auto-save-interval' 0 || return 1
  check 'Stopping auto-save returns failure for invalid paths' fails /bin/bash "$plugin_dir/glacier.tmux" >"$freeze_test_dir/plugin-output" 2>&1
  tmux set-option -gu '@frost-dir' || return 1
  check 'Unset @frost-dir uses the default path' test "$(frost_dir)" = "$default_frost_dir"
  tmux set-option -g '@frost-dir' "$freeze_test_dir/valid" || return 1
  check 'Use valid absolute path unchanged' test "$(frost_dir)" = "$freeze_test_dir/valid"
  for configured in "$freeze_test_dir/literal\\r" "$freeze_test_dir/literal\\\\r"; do
    tmux set-option -g '@frost-dir' "$configured" || return 1
    check 'Preserve literal backslash-r in valid paths' test "$(frost_dir)" = "$configured"
  done
  local LC_ALL=C
  export LC_ALL
  configured="$freeze_test_dir/한글"
  tmux -u set-option -g '@frost-dir' "$configured" || return 1
  check 'Preserve UTF-8 path outside tmux with C locale' test "$(TMUX='' frost_dir)" = "$configured"
  check 'Do not create a save file in fallback' test ! -e "$default_frost_cache_dir/last"
  freeze_test_cleanup
}

test_freeze_empty_line_guard() {
  freeze_test_setup || return 1
  local first snapshot
  first="$(tmux list-panes -t freeze-options -F '#{pane_id}')" || return 1
  tmux -u set-option -p -t "$first" '@ok' 1 || return 1
  # Real freeze already receives trailing blank lines from here-strings; success locks the guard.
  check 'Freeze succeeds with empty lines' run_real_freeze
  snapshot="$(resolve_symlink "$freeze_test_dir/saves/last")"
  check 'Snapshot exists after empty-line guard' test -f "$snapshot"
  check 'Options recorded after empty-line guard' grep -q $'pane_user_option\t' "$snapshot"
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
  run_freeze_test 'Freeze records' test_freeze_records
  run_freeze_test 'Freeze scope' test_freeze_scope
  run_freeze_test 'Preserve state on Freeze failure' test_freeze_failure_keeps_last
  run_freeze_test 'Thaw replacement' test_replace_and_empty_marker
  run_freeze_test 'Legacy and orphan Thaw' test_legacy_and_orphan
  run_freeze_test 'Orphan pane WARN succeeds' test_orphan_missing_pane_warn_success
  run_freeze_test 'frost_version compatibility' test_frost_version_write_and_compat
  run_freeze_test 'frost-dir guard and migration' test_frost_dir_guard_and_readonly_migrate
  run_freeze_test 'Migration snapshot selection' test_migration_selected_snapshot
  run_freeze_test 'Preserve current snapshot after migration' test_migration_current_snapshot_retention
  run_freeze_test 'Migration source path change' test_migration_source_change
  run_freeze_test 'Raw save path validation and failure propagation' test_frost_dir_raw_validation
  run_freeze_test 'Freeze empty-line guard' test_freeze_empty_line_guard
  run_freeze_test 'Thaw corrupt-pane isolation' test_corrupt_pane_isolation
  run_freeze_test 'Thaw corrupt-marker isolation' test_corrupt_marker_isolation
  run_freeze_test 'Thaw exact targets' test_exact_targets_and_duplicates
  run_freeze_test 'Thaw command failures' test_thaw_command_failures
  run_freeze_test 'Thaw special bytes' test_thaw_special_bytes
  run_freeze_test 'Server restart round trip' test_server_restart_round_trip
  run_freeze_test 'Name-list collisions and long names' test_colliding_name_sets_and_long_name
  test_name_listing_partial_failure
fi
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
