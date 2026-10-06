#!/usr/bin/env bash

# Reuse the isolated server and fault injection harness from the pane suite.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/pane_user_options_tests.sh
source "$SCRIPT_DIR/pane_user_options_tests.sh"

window_value_is() {
  local actual
  capture_option_value "$1" "$2" actual w && [ "$actual" = "$3" ]
}

window_option_absent() {
  local names encoded
  names="$(list_window_user_option_names "$1")" || return 1
  encoded="b64:$(printf '%s' "$2" | encode_base64)" || return 1
  ! printf '%s\n' "$names" | grep -Fxq "$encoded"
}

test_window_freeze_records() {
  freeze_test_setup || return 1
  local first pane snapshot count
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  pane="$(tmux display-message -p -t "$first" '#{pane_id}')" || return 1
  tmux split-window -d -t "$first" 'sleep 60' || return 1
  tmux new-window -d -t freeze-options:7 'sleep 60' || return 1
  tmux new-session -d -s other-options 'sleep 60' || return 1
  tmux set-option -g '@global-only' global || return 1
  tmux set-option -t freeze-options '@session-only' session || return 1
  tmux set-option -gw '@global-window-only' global-window || return 1
  tmux set-option -w -t "$first" '@shared' window || return 1
  tmux set-option -p -t "$pane" '@shared' pane || return 1
  tmux set-option -w -t "$first" '@empty' '' || return 1
  tmux set-option -w -t other-options:0 '@shared' other || return 1
  tmux set-option -w -t "$first" automatic-rename off || return 1
  tmux rename-window -t "$first" stable || return 1
  tmux set-option -w -t freeze-options:7 automatic-rename off || return 1
  tmux set-option -w -t other-options:0 automatic-rename off || return 1
  check_required 'Freeze windows succeeds' run_real_freeze || return 1
  snapshot="$(resolve_symlink "$freeze_test_dir/saves/last")"
  check 'Write format version 3' test "$(head -1 "$snapshot")" = $'frost_version\t3'
  check 'One marker per window path regardless of pane count' test "$(awk -F '\t' '$1 == "window_user_options" {n++} END {print n+0}' "$snapshot")" -eq 3
  check 'Keep empty window marker' grep -q $'^window_user_options\tfreeze-options\t7$' "$snapshot"
  check 'Window marker and option field counts' awk -F '\t' '$1 == "window_user_options" && NF != 3 {exit 1} $1 == "window_user_option" && NF != 5 {exit 1}' "$snapshot"
  check 'Persist only three local window user options' test "$(awk -F '\t' '$1 == "window_user_option" {n++} END {print n+0}' "$snapshot")" -eq 3
  check 'Window and pane user option values are separate' grep -q $'^window_user_option\tfreeze-options\t0\tb64:QHNoYXJlZA==\tb64:d2luZG93$' "$snapshot"
  check 'Other session keeps its separate window user option value' grep -q $'^window_user_option\tother-options\t0\tb64:QHNoYXJlZA==\tb64:b3RoZXI=$' "$snapshot"
  count="$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')"
  check 'Identical windows Freeze succeeds' run_real_freeze
  check 'Identical options do not add snapshots' test "$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')" -eq "$count"
  tmux set-option -w -t "$first" '@shared' changed || return 1
  check 'Changed window user option value Freeze succeeds' run_real_freeze
  check 'Window user option change adds one snapshot' test "$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')" -eq "$((count + 1))"
  freeze_test_cleanup
}

test_window_linked_paths() {
  freeze_test_setup || return 1
  local first snapshot
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  tmux new-session -d -s linked-options 'sleep 60' || return 1
  tmux link-window -s "$first" -t linked-options:4 || return 1
  tmux set-option -w -t "$first" '@linked' saved || return 1
  check_required 'Freeze linked window paths' run_real_freeze || return 1
  snapshot="$freeze_test_dir/saves/last"
  check 'Linked window records each session/index path' test "$(awk -F '\t' '$1 == "window_user_options" {n++} END {print n+0}' "$snapshot")" -eq 3
  check 'First path has local option record' grep -q $'^window_user_option\tfreeze-options\t0\tb64:QGxpbmtlZA==\tb64:c2F2ZWQ=$' "$snapshot"
  check 'Linked path has the same local option record' grep -q $'^window_user_option\tlinked-options\t4\tb64:QGxpbmtlZA==\tb64:c2F2ZWQ=$' "$snapshot"
  tmux set-option -w -t "$first" '@linked' OLD || return 1
  check 'Thaw existing linked window paths' run_real_thaw
  check 'Restore shared window user option once per path' window_value_is "$first" '@linked' saved
  check 'Keep existing link identity' test "$(tmux display-message -p -t linked-options:4 '#{window_id}')" = "$first"
  freeze_test_cleanup
}

test_window_replace_and_scope() {
  freeze_test_setup || return 1
  local first second third pane
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  second="$(tmux new-window -d -P -F '#{window_id}' -t freeze-options:7 'sleep 60')" || return 1
  third="$(tmux new-session -d -P -F '#{window_id}' -s freeze-options-extra 'sleep 60')" || return 1
  pane="$(tmux display-message -p -t "$first" '#{pane_id}')" || return 1
  tmux set-option -g '@shared' global || return 1
  tmux set-option -t freeze-options '@shared' session || return 1
  tmux set-option -gw '@shared' global-window || return 1
  tmux set-option -w -t "$first" '@shared' window || return 1
  tmux set-option -p -t "$pane" '@shared' pane || return 1
  tmux set-option -w -t "$first" '@empty' '' || return 1
  tmux set-option -w -t "$third" '@shared' other-session || return 1
  tmux set-option -w -t "$first" automatic-rename off || return 1
  tmux rename-window -t "$first" stable || return 1
  check_required 'Freeze scope snapshot' run_real_freeze || return 1
  tmux set-option -w -t "$first" '@shared' OLD || return 1
  tmux set-option -w -t "$first" '@stale' OLD || return 1
  tmux set-option -w -t "$second" '@stale' OLD || return 1
  tmux set-option -p -t "$pane" '@shared' OLD || return 1
  tmux set-option -w -t "$third" '@shared' OLD || return 1
  check 'Thaw restores both option scopes' run_real_thaw
  check 'Restore local window user option value' window_value_is "$first" '@shared' window
  check 'Restore local pane user option value' pane_value_is "$pane" '@shared' pane
  check 'Restore same index in similar session separately' window_value_is "$third" '@shared' other-session
  check 'Preserve global value' test "$(tmux show-options -gv '@shared')" = global
  check 'Preserve session value' test "$(tmux show-options -v -t freeze-options '@shared')" = session
  check 'Preserve global window user option value' test "$(tmux show-options -gwv '@shared')" = global-window
  check 'Remove stale local window user option' window_option_absent "$first" '@stale'
  check 'Empty window marker removes all local user options' window_option_absent "$second" '@stale'
  check 'Empty window keeps inherited options visible' tmux show-options -wA -t "$second" '@shared'
  check 'Keep empty value as a local option' tmux show-options -w -t "$first" '@empty'
  check 'Restore empty window user option value' window_value_is "$first" '@empty' ''
  tmux set-option -w -t "$second" '@stale' again || return 1
  check 'Repeated Thaw succeeds' run_real_thaw
  check 'Repeated Thaw removes stale window user option' window_option_absent "$second" '@stale'
  check 'Repeated Thaw keeps window count' test "$(tmux list-windows -t freeze-options | wc -l | tr -d ' ')" -eq 2
  check 'Repeated Thaw keeps pane count' test "$(tmux list-panes -a | wc -l | tr -d ' ')" -eq 3
  freeze_test_cleanup
}

test_window_legacy_targets_and_duplicates() {
  freeze_test_setup || return 1
  local first record version
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  tmux set-option -w -t "$first" '@foo' OLD || return 1
  GLACIER_TRACE="$freeze_test_dir/trace"
  export GLACIER_TRACE
  for version in 1 2 3; do
    printf 'frost_version\t%s\n' "$version" >"$freeze_test_dir/saves/manual.txt"
    ln -sf manual.txt "$freeze_test_dir/saves/last" || return 1
    check "Version $version without window markers succeeds" run_real_thaw
    check "Version $version without markers keeps options" window_value_is "$first" '@foo' OLD
  done
  for record in $'window_user_options\tfreeze\t0' $'window_user_options\tfreeze-options\t99'; do
    printf '%s\n' "$record" | write_thaw_snapshot || return 1
    : >"$GLACIER_TRACE"
    check 'Missing exact window logs WARN and succeeds' run_real_thaw
    check 'Missing target warning' grep -q 'orphan thaw' "$freeze_test_dir/saves/"*.log
    check 'No similar-session or current-window fallback' window_value_is "$first" '@foo' OLD
    check 'No writes for absent window' is_empty "$GLACIER_TRACE"
  done
  for record in \
    $'window_user_options\t\t0' $'window_user_options\tfreeze-options\t' \
    $'window_user_options\tfreeze-options\tx' $'window_user_options\tfreeze-options\t-1' \
    $'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ=='; do
    printf '%s\n' "$record" | write_thaw_snapshot || return 1
    : >"$GLACIER_TRACE"
    check 'Invalid identifier or missing marker fails' fails run_real_thaw
    check 'Invalid record preserves current options' window_value_is "$first" '@foo' OLD
    check 'No writes for invalid target or orphan record' is_empty "$GLACIER_TRACE"
  done
  {
    printf 'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ==\n'
    printf 'window_user_options\tfreeze-options\t0\nwindow_user_options\tfreeze-options\t0\n'
    printf 'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:Qg==\n'
    printf 'window_user_option\tfreeze-options\t0\tb64:QGVtcHR5\tb64:\n'
  } | write_thaw_snapshot || return 1
  : >"$GLACIER_TRACE"
  check 'Duplicate markers and reversed records succeed' run_real_thaw
  check 'Duplicate name uses last value' window_value_is "$first" '@foo' B
  check 'Empty value survives duplicate records' window_value_is "$first" '@empty' ''
  check 'Duplicate markers replace once' test "$(awk -F '\t' '$1 == "-uw" {n++} END {print n+0}' "$GLACIER_TRACE")" -eq 1
  printf 'frost_version\t4\nwindow_user_options\tfreeze-options\t0\n' >"$freeze_test_dir/saves/manual.txt"
  : >"$GLACIER_TRACE"
  check 'Unsupported version fails before mutation' fails run_real_thaw
  check 'Unsupported version preserves window user options' window_value_is "$first" '@foo' B
  check 'Unsupported version issues no writes' is_empty "$GLACIER_TRACE"
  freeze_test_cleanup
}

test_window_corrupt_records() {
  freeze_test_setup || return 1
  local first second pane record malformed order
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  second="$(tmux new-window -d -P -F '#{window_id}' -t freeze-options:7 'sleep 60')" || return 1
  pane="$(tmux display-message -p -t "$first" '#{pane_id}')" || return 1
  GLACIER_TRACE="$freeze_test_dir/trace"
  export GLACIER_TRACE
  for record in \
    $'window_user_option\tfreeze-options\t0' \
    $'window_user_option\tfreeze-options\t0\t\tb64:QQ==' \
    $'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\t' \
    $'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ==\textra' \
    $'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ==\t' \
    $'window_user_option\tfreeze-options\t0\tQGZvbw==\tb64:QQ==' \
    $'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tQQ==' \
    $'window_user_option\tfreeze-options\t0\tb64:***\tb64:QQ==' \
    $'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:***' \
    $'window_user_option\tfreeze-options\t0\tb64:YXV0b21hdGljLXJlbmFtZQ==\tb64:QQ==' \
    $'window_user_option\tfreeze-options\t0\tb64:\tb64:QQ=='; do
    tmux set-option -w -t "$first" '@foo' OLD || return 1
    tmux set-option -w -t "$second" '@foo' OLD || return 1
    tmux set-option -p -t "$pane" '@foo' OLD || return 1
    {
      printf 'window_user_options\tfreeze-options\t0\n'
      printf 'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ==\n'
      printf '%s\n' "$record"
      printf 'window_user_options\tfreeze-options\t7\n'
      printf 'window_user_option\tfreeze-options\t7\tb64:QGZvbw==\tb64:Qg==\n'
      printf 'pane_user_options\tfreeze-options\t0\t0\n'
      printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:Qw==\n'
    } | write_thaw_snapshot || return 1
    : >"$GLACIER_TRACE"
    check 'Corrupt window record fails Thaw' fails run_real_thaw
    check 'Corrupt window keeps existing set' window_value_is "$first" '@foo' OLD
    check 'Other window still restores' window_value_is "$second" '@foo' B
    check 'Pane stage still restores' pane_value_is "$pane" '@foo' C
    check 'Corrupt window receives no writes' fails grep -Fq "$first" "$GLACIER_TRACE"
  done
  for malformed in $'window_user_options\tfreeze-options\t0\textra' $'window_user_options\tfreeze-options\t0\t'; do
    for order in before after; do
      tmux set-option -w -t "$first" '@foo' OLD || return 1
      {
        [ "$order" != before ] || printf '%s\n' "$malformed"
        printf 'window_user_options\tfreeze-options\t0\n'
        printf 'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ==\n'
        [ "$order" != after ] || printf '%s\n' "$malformed"
      } | write_thaw_snapshot || return 1
      check 'Malformed marker fails overall result' fails run_real_thaw
      check 'Valid marker still restores its window' window_value_is "$first" '@foo' A
    done
    tmux set-option -w -t "$first" '@foo' OLD || return 1
    printf '%s\n' "$malformed" | write_thaw_snapshot || return 1
    check 'Malformed marker alone fails' fails run_real_thaw
    check 'Malformed marker alone preserves options' window_value_is "$first" '@foo' OLD
  done
  check 'Errors do not log complete success' fails grep -q 'thaw complete' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_window_command_failures() {
  freeze_test_setup || return 1
  local first second pane mode
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  second="$(tmux new-window -d -P -F '#{window_id}' -t freeze-options:7 'sleep 60')" || return 1
  pane="$(tmux display-message -p -t "$first" '#{pane_id}')" || return 1
  GLACIER_TRACE="$freeze_test_dir/trace"
  GLACIER_FAIL_WINDOW="$first"
  export GLACIER_TRACE GLACIER_FAIL_WINDOW
  {
    printf 'window_user_options\tfreeze-options\t0\n'
    printf 'window_user_option\tfreeze-options\t0\tb64:QGZvbw==\tb64:QQ==\n'
    printf 'window_user_option\tfreeze-options\t0\tb64:QGZhaWw=\tb64:bm8tbG9nLXNlY3JldA==\n'
    printf 'window_user_option\tfreeze-options\t0\tb64:QGFmdGVy\tb64:Qw==\n'
    printf 'window_user_options\tfreeze-options\t7\n'
    printf 'window_user_option\tfreeze-options\t7\tb64:QGZvbw==\tb64:Qg==\n'
    printf 'pane_user_options\tfreeze-options\t0\t0\n'
    printf 'pane_user_option\tfreeze-options\t0\t0\tb64:QGZvbw==\tb64:UA==\n'
  } | write_thaw_snapshot || return 1
  for mode in thaw-window-list thaw-window-unset thaw-window-set window-dump; do
    tmux set-option -w -t "$first" '@foo' OLD || return 1
    tmux set-option -w -t "$first" '@stale' OLD || return 1
    tmux set-option -w -t "$second" '@foo' OLD || return 1
    tmux set-option -p -t "$pane" '@foo' OLD || return 1
    : >"$GLACIER_TRACE"
    GLACIER_FAIL_MODE="$mode"
    export GLACIER_FAIL_MODE
    check "$mode reports failure" fails run_real_thaw
    unset GLACIER_FAIL_MODE
    check "$mode keeps pane stage running" pane_value_is "$pane" '@foo' P
    if [ "$mode" != window-dump ]; then
      check "$mode continues other windows" window_value_is "$second" '@foo' B
    fi
    if [ "$mode" = thaw-window-set ]; then
      check 'Set failure still applies later options' window_value_is "$first" '@after' C
      check 'Failed option is absent' window_option_absent "$first" '@fail'
    else
      check "$mode preserves existing option" window_value_is "$first" '@foo' OLD
      check "$mode does not set failed window" fails awk -F '\t' -v id="$first" '$1 == "-w" && $2 == id {found=1} END {exit !found}' "$GLACIER_TRACE"
    fi
    check 'Logs and output omit values and raw diagnostics' fails grep -Eq 'no-log-secret|hidden-diagnostic' "$freeze_test_dir/saves/"*.log "$freeze_test_dir/thaw-output"
  done
  check 'Command errors do not log complete success' fails grep -q 'thaw complete' "$freeze_test_dir/saves/"*.log
  freeze_test_cleanup
}

test_window_freeze_failures() {
  freeze_test_setup || return 1
  local first mode old_target count old_log_count
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  tmux set-option -w -t "$first" '@fault' before || return 1
  check_required 'Baseline window snapshot' run_real_freeze || return 1
  old_target="$(readlink "$freeze_test_dir/saves/last")"
  cp "$freeze_test_dir/saves/last" "$freeze_test_dir/original" || return 1
  tmux set-option -w -t "$first" '@fault' after || return 1
  count="$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')"
  old_log_count="$(grep -c 'freeze complete' "$freeze_test_dir/saves/"*.log)"
  for mode in window-dump window-list window-query encode write; do
    GLACIER_FAIL_MODE="$mode"
    export GLACIER_FAIL_MODE
    check "$mode aborts window snapshot" fails run_real_freeze
    unset GLACIER_FAIL_MODE
    check "$mode keeps last link" test "$(readlink "$freeze_test_dir/saves/last")" = "$old_target"
    check "$mode keeps snapshot bytes" same_file "$freeze_test_dir/original" "$freeze_test_dir/saves/last"
    check "$mode publishes no snapshot" test "$(find "$freeze_test_dir/saves" -name 'frost_*.txt' | wc -l | tr -d ' ')" -eq "$count"
    check "$mode cleans temporary save" test "$(find "$freeze_test_dir/saves" -name '.frost-save.*' | wc -l | tr -d ' ')" -eq 0
    check "$mode emits no success log" test "$(grep -c 'freeze complete' "$freeze_test_dir/saves/"*.log)" -eq "$old_log_count"
  done
  freeze_test_cleanup
}

test_window_special_bytes() {
  freeze_test_setup || return 1
  local first name value prepared long_name i expected current second
  first="$(tmux display-message -p -t freeze-options:0 '#{window_id}')" || return 1
  value=$'한글\t"quotes"\\backslash\ninside\n\n'
  while [ "${#value}" -lt 270 ]; do value="${value}x"; done
  value="${value}"$'\n\n'
  long_name='@long'
  while [ "${#long_name}" -lt 260 ]; do long_name="${long_name}x"; done
  for name in '@' '@a b' '@한글 이름' "@'quote" $'@tab\tname' $'@line\nend\n' '@"quote' '@#{window_id}' '@semi;' '@back\;' "$long_name"; do
    prepare_tmux_option_name "$name" prepared
    tmux -u set-option -w -t "$first" "$prepared" "$value" || return 1
  done
  for i in 0 1 2 3; do
    expected=';'
    while [ "${#expected}" -le "$i" ]; do expected="\\${expected}"; done
    escape_tmux_argument "$expected" prepared
    tmux -u set-option -w -t "$first" "@end$i" "$prepared" || return 1
  done
  tmux set-option -w -t "$first" '@literal' '#{window_id}' || return 1
  # Listing text alone cannot distinguish one multiline name from two names.
  second="$(tmux new-window -d -P -F '#{window_id}' -t freeze-options:7 'sleep 60')" || return 1
  tmux set-option -w -t "$second" $'@a one\n@b' two || return 1
  check_required 'Freeze special window bytes' run_real_freeze || return 1
  for name in '@' '@a b' '@한글 이름' "@'quote" $'@tab\tname' $'@line\nend\n' '@"quote' '@#{window_id}' '@semi;' '@back\;' "$long_name"; do
    prepare_tmux_option_name "$name" prepared
    tmux -u set-option -w -t "$first" "$prepared" OLD || return 1
  done
  check 'Thaw special window bytes' run_real_thaw
  printf '%s' "$value" >"$freeze_test_dir/expected-value"
  for name in '@' '@a b' '@한글 이름' "@'quote" $'@tab\tname' $'@line\nend\n' '@"quote' '@#{window_id}' '@semi;' '@back\;' "$long_name"; do
    capture_option_value "$first" "$name" current w || return 1
    printf '%s' "$current" >"$freeze_test_dir/actual-value"
    check 'Compare special window bytes exactly' same_file "$freeze_test_dir/expected-value" "$freeze_test_dir/actual-value"
  done
  for i in 0 1 2 3; do
    expected=';'
    while [ "${#expected}" -le "$i" ]; do expected="\\${expected}"; done
    check 'Preserve backslashes and final semicolon' window_value_is "$first" "@end$i" "$expected"
  done
  check 'Preserve literal format value' window_value_is "$first" '@literal' '#{window_id}'
  check 'Preserve multiline colliding name' window_value_is "$second" $'@a one\n@b' two
  freeze_test_cleanup
}

test_window_server_restart() {
  freeze_test_setup || return 1
  local first second pane old_id layout
  tmux new-window -d -t freeze-options:3 'sleep 60' || return 1
  tmux kill-window -t freeze-options:0 || return 1
  first="$(tmux display-message -p -t freeze-options:3 '#{window_id}')" || return 1
  second="$(tmux new-window -d -P -F '#{window_id}' -t freeze-options:7 'sleep 60')" || return 1
  pane="$(tmux display-message -p -t "$first" '#{pane_id}')" || return 1
  tmux split-window -d -t "$first" 'sleep 60' || return 1
  tmux select-layout -t "$first" even-horizontal >/dev/null || return 1
  tmux set-option -w -t "$first" '@shared' window || return 1
  tmux set-option -p -t "$pane" '@shared' pane || return 1
  tmux set-option -w -t "$first" automatic-rename off || return 1
  tmux rename-window -t "$first" saved-name || return 1
  layout="$(tmux list-panes -t "$first" -F '#{pane_left},#{pane_top},#{pane_width},#{pane_height}')"
  old_id="$first"
  check_required 'Freeze before server restart' run_real_freeze || return 1
  tmux kill-server || return 1
  GLACIER_TEST_SOCKET="$freeze_test_dir/socket-restored"
  TMUX="$GLACIER_TEST_SOCKET,1,0"
  export GLACIER_TEST_SOCKET TMUX
  tmux -f /dev/null new-session -d -s seed 'sleep 60' || return 1
  # Consume IDs so restore cannot accidentally rely on IDs from the old server.
  tmux new-window -d -t seed 'sleep 60' || return 1
  tmux new-window -d -t seed 'sleep 60' || return 1
  tmux set-option -g '@frost-dir' "$freeze_test_dir/saves" || return 1
  check_required 'Thaw on fresh server' run_real_thaw || return 1
  first="$(tmux display-message -p -t freeze-options:3 '#{window_id}')" || return 1
  second="$(tmux display-message -p -t freeze-options:7 '#{window_id}')" || return 1
  pane="$(tmux display-message -p -t freeze-options:3.0 '#{pane_id}')" || return 1
  check 'Recreated window ID changes' test "$first" != "$old_id"
  check 'Restore window scope on new ID' window_value_is "$first" '@shared' window
  check 'Restore pane scope on new ID' pane_value_is "$pane" '@shared' pane
  check 'Restore empty window set' window_option_absent "$second" '@shared'
  check 'Restore saved built-in window name' test "$(tmux display-message -p -t "$first" '#{window_name}')" = saved-name
  check 'Restore automatic-rename' test "$(tmux show-options -wv -t "$first" automatic-rename)" = off
  check 'Restore saved window layout geometry' test "$(tmux list-panes -t "$first" -F '#{pane_left},#{pane_top},#{pane_width},#{pane_height}')" = "$layout"
  check 'Restore both nonzero window indices' test "$(tmux list-windows -t freeze-options -F '#{window_index}')" = $'3\n7'
  tmux set-option -w -t "$second" '@stale' OLD || return 1
  check 'Repeat Thaw on recreated windows' run_real_thaw
  check 'Repeat Thaw clears empty set' window_option_absent "$second" '@stale'
  freeze_test_cleanup
}

if [ "$#" -gt 0 ]; then
  for test_function in "$@"; do
    run_freeze_test "$test_function" "$test_function"
  done
else
  run_freeze_test 'Window user option Freeze records' test_window_freeze_records
  run_freeze_test 'Linked window paths' test_window_linked_paths
  run_freeze_test 'Window user option replacement and scope' test_window_replace_and_scope
  run_freeze_test 'Window user option legacy targets and duplicates' test_window_legacy_targets_and_duplicates
  run_freeze_test 'Window user option corrupt record isolation' test_window_corrupt_records
  run_freeze_test 'Window user option command failures' test_window_command_failures
  run_freeze_test 'Window user option Freeze failures' test_window_freeze_failures
  run_freeze_test 'Window user option special bytes' test_window_special_bytes
  run_freeze_test 'Window user options after server restart' test_window_server_restart
fi
printf 'Results: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
