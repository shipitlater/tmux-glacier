#!/usr/bin/env bash
#
# tmux-glacier test suite
#
# Runs against an isolated tmux server (dedicated socket).
# Usage: ./tests/run_tests.sh

set -euo pipefail

SOCKET="/tmp/tmux-glacier-test-$$"
SAVE_DIR="/tmp/tmux-glacier-test-saves-$$"
SESSION="glacier-test"

# Kill any orphaned test servers from previous interrupted runs
for orphan_sock in /tmp/tmux-glacier-test-[0-9]*; do
    [ -S "$orphan_sock" ] || continue
    [ "$orphan_sock" = "$SOCKET" ] && continue
    tmux -S "$orphan_sock" kill-server 2>/dev/null || true
    rm -f "$orphan_sock"
done
for orphan_dir in /tmp/tmux-glacier-test-saves-[0-9]*; do
    [ -d "$orphan_dir" ] || continue
    [ "$orphan_dir" = "$SAVE_DIR" ] && continue
    rm -rf "$orphan_dir"
done

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

cleanup() {
    tmux -S "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$SAVE_DIR" "$SOCKET"
}
trap cleanup EXIT

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }
section() { echo -e "\n${YELLOW}── $1 ──${NC}"; }

# Shortcut: run tmux on our test socket
T() { tmux -S "$SOCKET" "$@"; }

# Get base-index from the test server
base_idx() { T show -gv base-index 2>/dev/null || echo 0; }

# Start a fresh tmux server with a session
fresh_server() {
    T kill-server 2>/dev/null || true
    rm -rf "$SAVE_DIR"
    mkdir -p "$SAVE_DIR"
    # Wait for socket to be fully released after kill-server
    local retries=0
    while [ -S "$SOCKET" ] && [ $retries -lt 10 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done
    rm -f "$SOCKET"
    T new-session -d -s "$SESSION" -x 200 -y 50
}

# ── Inline freeze/thaw that operate on $SOCKET ────────────────────

d=$'\t'

do_freeze() {
    local save_file
    save_file="$SAVE_DIR/frost_$(date +%Y%m%dT%H%M%S%N).txt"

    echo "frost_version${d}2" > "$save_file"

    T list-panes -a \
        -F "pane${d}#{session_name}${d}#{window_index}${d}#{window_active}${d}#{pane_index}${d}#{pane_title}${d}:#{pane_current_path}${d}#{pane_active}" \
        >> "$save_file"

    # Windows with layout validation
    T list-windows -a \
        -F "window${d}#{session_name}${d}#{window_index}${d}:#{window_name}${d}#{window_active}${d}:#{window_flags}${d}#{window_layout}${d}:" |
        while IFS=$'\t' read -r lt ses win wname wact wfl wlay auto; do
            local pane_count=0 any_tiny=false
            while IFS=$'\t' read -r ph; do
                pane_count=$((pane_count + 1))
                if [ "$ph" -le 1 ] 2>/dev/null; then any_tiny=true; fi
            done < <(T list-panes -t "${ses}:${win}" -F "#{pane_height}" 2>/dev/null)
            if [ "$pane_count" -gt 1 ] && [ "$any_tiny" = "true" ]; then
                wlay="tiled"
            fi
            echo "${lt}${d}${ses}${d}${win}${d}${wname}${d}${wact}${d}${wfl}${d}${wlay}${d}${auto}"
        done >> "$save_file"

    T display-message -p "state${d}#{client_session}${d}#{client_last_session}" >> "$save_file" 2>/dev/null || \
        echo "state${d}${SESSION}${d}" >> "$save_file"

    ln -fs "$(basename "$save_file")" "$SAVE_DIR/last"
    echo "$save_file"
}

do_thaw() {
    local save_file="$1"
    local width="${2:-200}" height="${3:-50}"
    local first_pane=true
    local first_session_window=""
    local created_sessions=""

    # shellcheck disable=SC2034  # positional fields needed to reach r_dir
    while IFS=$'\t' read -r line_type r_session r_win r_winactive r_paneidx r_title r_dir r_paneactive; do
        [ "$line_type" = "pane" ] || continue
        r_dir="${r_dir#:}"

        if [ "$first_pane" = "true" ]; then
            TMUX="" T new-session -d -s "$r_session" -x "$width" -y "$height" -c "$r_dir"
            local first_win
            first_win="$(T show -gv base-index)"
            if [ "$first_win" != "$r_win" ]; then
                T move-window -s "${r_session}:${first_win}" -t "${r_session}:${r_win}"
            fi
            first_pane=false
            first_session_window="${r_session}:${r_win}"
            created_sessions="${r_session}"
        elif [ "${r_session}:${r_win}" = "$first_session_window" ]; then
            T split-window -t "${r_session}:${r_win}" -c "$r_dir"
            T resize-pane -t "${r_session}:${r_win}" -U "999"
            first_session_window=""
        else
            if ! echo "$created_sessions" | grep -q "^${r_session}$" && ! T has-session -t "$r_session" 2>/dev/null; then
                TMUX="" T new-session -d -s "$r_session" -x "$width" -y "$height" -c "$r_dir"
                created_sessions="${created_sessions}
${r_session}"
                first_session_window="${r_session}:${r_win}"
            elif ! T list-windows -t "$r_session" -F "#{window_index}" 2>/dev/null | grep -q "^${r_win}$"; then
                T new-window -d -t "${r_session}:${r_win}" -c "$r_dir"
            else
                T split-window -t "${r_session}:${r_win}" -c "$r_dir"
                T resize-pane -t "${r_session}:${r_win}" -U "999"
            fi
        fi
    done < "$save_file"
}

do_apply_layouts() {
    local save_file="$1"
    # shellcheck disable=SC2034  # positional fields needed to reach r_layout
    while IFS=$'\t' read -r line_type r_session r_win r_name r_active r_flags r_layout r_autorename; do
        [ "$line_type" = "window" ] || continue
        T select-layout -t "${r_session}:${r_win}" "$r_layout" 2>/dev/null || true
    done < "$save_file"
}

# Count panes for a given target (session or session:window)
pane_count() {
    T list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '
}

# Get the list of window indices for a session
window_indices() {
    T list-windows -t "$1" -F "#{window_index}" 2>/dev/null | sort -n
}

# ════════════════════════════════════════════════════════════════════
# Tests
# ════════════════════════════════════════════════════════════════════

test_save_file_format() {
    section "Save file format"
    fresh_server

    local save_file
    save_file="$(do_freeze)"

    # Version header
    local first_line
    first_line="$(head -1 "$save_file")"
    if [[ "$first_line" == "frost_version"*"2" ]]; then
        pass "version header present"
    else
        fail "version header missing or wrong: $first_line"
    fi

    # Contains pane lines
    if grep -q "^pane${d}" "$save_file"; then
        pass "pane lines present"
    else
        fail "no pane lines found"
    fi

    # Contains window lines
    if grep -q "^window${d}" "$save_file"; then
        pass "window lines present"
    else
        fail "no window lines found"
    fi

    # Contains state line
    if grep -q "^state${d}" "$save_file"; then
        pass "state line present"
    else
        fail "no state line found"
    fi

    # Pane line field count (8 fields)
    local pane_fields
    pane_fields="$(grep "^pane${d}" "$save_file" | head -1 | awk -F'\t' '{print NF}')"
    if [ "$pane_fields" -eq 8 ]; then
        pass "pane line has 8 fields"
    else
        fail "pane line has $pane_fields fields (expected 8)"
    fi

    # Window line field count (8 fields)
    local win_fields
    win_fields="$(grep "^window${d}" "$save_file" | head -1 | awk -F'\t' '{print NF}')"
    if [ "$win_fields" -eq 8 ]; then
        pass "window line has 8 fields"
    else
        fail "window line has $win_fields fields (expected 8)"
    fi
}

test_last_symlink() {
    section "Last symlink"
    fresh_server

    local save_file
    save_file="$(do_freeze)"
    local last="$SAVE_DIR/last"

    if [ -L "$last" ]; then
        pass "last symlink created"
    else
        fail "last symlink not created"
        return
    fi

    local target
    target="$(readlink "$last")"
    if [ "$target" = "$(basename "$save_file")" ]; then
        pass "last symlink points to latest save"
    else
        fail "last symlink points to '$target', expected '$(basename "$save_file")'"
    fi

    # Second save should update the symlink
    sleep 0.1
    local save_file2
    save_file2="$(do_freeze)"
    target="$(readlink "$last")"
    if [ "$target" = "$(basename "$save_file2")" ]; then
        pass "last symlink updated on second save"
    else
        fail "last symlink not updated: $target"
    fi
}

test_layout_validation() {
    section "Layout validation"
    fresh_server

    # Create 4 panes
    T split-window -t "$SESSION"
    T split-window -t "$SESSION"
    T split-window -t "$SESSION"
    T select-layout -t "$SESSION" tiled

    # Normal save — layout should be a computed layout string
    local save_file
    save_file="$(do_freeze)"
    local layout
    layout="$(grep "^window${d}" "$save_file" | head -1 | cut -f7)"

    if [ -n "$layout" ]; then
        pass "layout captured for healthy panes"
    else
        fail "no layout captured"
    fi

    # Now simulate stacked state: create panes and resize them to tiny
    fresh_server
    T split-window -t "$SESSION"
    T split-window -t "$SESSION"
    T split-window -t "$SESSION"
    # Stack them by resizing to minimum
    T resize-pane -t "$SESSION" -U 999

    save_file="$(do_freeze)"
    layout="$(grep "^window${d}" "$save_file" | head -1 | cut -f7)"
    if [ "$layout" = "tiled" ]; then
        pass "stacked layout replaced with 'tiled'"
    else
        fail "stacked layout NOT replaced: '$layout'"
    fi
}

test_round_trip_single_session() {
    section "Round-trip: single session"
    fresh_server

    # Create 3 panes
    T split-window -t "$SESSION"
    T split-window -t "$SESSION"
    T select-layout -t "$SESSION" tiled

    local save_file
    save_file="$(do_freeze)"

    local orig_panes
    orig_panes="$(pane_count "$SESSION")"

    T kill-session -t "$SESSION"
    do_thaw "$save_file"
    do_apply_layouts "$save_file"

    local restored_panes
    restored_panes="$(pane_count "$SESSION")"

    if [ "$restored_panes" -eq "$orig_panes" ]; then
        pass "pane count preserved ($orig_panes)"
    else
        fail "pane count mismatch: had $orig_panes, restored $restored_panes"
    fi
}

test_round_trip_multi_window() {
    section "Round-trip: multiple windows"
    fresh_server

    local bi
    bi="$(base_idx)"
    local win1=$bi
    local win2=$((bi + 1))

    # Create a second window with 2 panes
    T new-window -t "${SESSION}:${win2}"
    T split-window -t "${SESSION}:${win2}"
    T select-layout -t "${SESSION}:${win2}" even-horizontal

    # Name the windows
    T rename-window -t "${SESSION}:${win1}" "editor"
    T rename-window -t "${SESSION}:${win2}" "build"

    local save_file
    save_file="$(do_freeze)"

    local orig_win_count
    orig_win_count="$(T list-windows -t "$SESSION" | wc -l | tr -d ' ')"

    T kill-session -t "$SESSION"
    do_thaw "$save_file"
    do_apply_layouts "$save_file"

    local restored_win_count
    restored_win_count="$(T list-windows -t "$SESSION" | wc -l | tr -d ' ')"

    if [ "$restored_win_count" -eq "$orig_win_count" ]; then
        pass "window count preserved ($orig_win_count)"
    else
        fail "window count mismatch: had $orig_win_count, restored $restored_win_count"
    fi

    # Check pane counts per window
    local w1_panes w2_panes
    w1_panes="$(pane_count "${SESSION}:${win1}")"
    w2_panes="$(pane_count "${SESSION}:${win2}")"
    if [ "$w1_panes" -eq 1 ] && [ "$w2_panes" -eq 2 ]; then
        pass "per-window pane counts correct (1, 2)"
    else
        fail "per-window pane counts wrong: win ${win1}=${w1_panes}, win ${win2}=${w2_panes} (expected 1, 2)"
    fi
}

test_round_trip_multi_session() {
    section "Round-trip: multiple sessions"
    fresh_server

    # Create a second session
    T new-session -d -s "other" -x 200 -y 50
    T split-window -t "other"

    local save_file
    save_file="$(do_freeze)"

    T kill-server 2>/dev/null || true
    sleep 0.1

    do_thaw "$save_file"
    do_apply_layouts "$save_file"

    if T has-session -t "$SESSION" 2>/dev/null; then
        pass "session '$SESSION' restored"
    else
        fail "session '$SESSION' not restored"
    fi

    if T has-session -t "other" 2>/dev/null; then
        pass "session 'other' restored"
    else
        fail "session 'other' not restored"
    fi

    local other_panes
    other_panes="$(pane_count "other")"
    if [ "$other_panes" -eq 2 ]; then
        pass "session 'other' has correct pane count (2)"
    else
        fail "session 'other' pane count: $other_panes (expected 2)"
    fi
}

test_window_names_restored() {
    section "Window names"
    fresh_server

    local bi
    bi="$(base_idx)"
    local win1=$bi
    local win2=$((bi + 1))

    T rename-window -t "${SESSION}:${win1}" "my-editor"
    T new-window -t "${SESSION}:${win2}" -n "my-logs"

    local save_file
    save_file="$(do_freeze)"
    T kill-session -t "$SESSION"
    do_thaw "$save_file"
    do_apply_layouts "$save_file"

    # Apply window names from save file
    while IFS=$'\t' read -r lt ses win wname wact wfl wlay auto; do
        [ "$lt" = "window" ] || continue
        wname="${wname#:}"
        T rename-window -t "${ses}:${win}" "$wname" 2>/dev/null || true
    done < "$save_file"

    local name1 name2
    name1="$(T display-message -t "${SESSION}:${win1}" -p '#{window_name}')"
    name2="$(T display-message -t "${SESSION}:${win2}" -p '#{window_name}')"

    if [ "$name1" = "my-editor" ]; then
        pass "window $win1 name restored: my-editor"
    else
        fail "window $win1 name: '$name1' (expected 'my-editor')"
    fi

    if [ "$name2" = "my-logs" ]; then
        pass "window $win2 name restored: my-logs"
    else
        fail "window $win2 name: '$name2' (expected 'my-logs')"
    fi
}

test_pane_cwd_captured() {
    section "Pane working directory"
    fresh_server

    local save_file
    save_file="$(do_freeze)"

    local cwd_field
    cwd_field="$(grep "^pane${d}" "$save_file" | head -1 | cut -f7)"

    # Should start with ":" prefix followed by a path
    if [[ "$cwd_field" == :/* ]]; then
        pass "pane cwd captured with : prefix (${cwd_field:0:30}...)"
    else
        fail "pane cwd format wrong: '$cwd_field'"
    fi
}

test_backup_retention() {
    section "Backup retention"
    fresh_server

    # Create 8 save files with different timestamps
    for i in $(seq 1 8); do
        local f="$SAVE_DIR/frost_2025010${i}T120000.txt"
        echo "frost_version${d}1" > "$f"
        echo "pane${d}test${d}0${d}1${d}0${d}title${d}:/tmp${d}1" >> "$f"
        touch -d "2025-01-0${i}" "$f" 2>/dev/null || touch "$f"
    done

    # The retention logic sorts by mtime and keeps newest 5
    local old_files
    old_files="$(ls -t "$SAVE_DIR"/frost_*.txt | tail -n +6 | wc -l | tr -d ' ')"
    if [ "$old_files" -eq 3 ]; then
        pass "identified 3 files beyond the 5 newest"
    else
        fail "expected 3 old files, found $old_files"
    fi
}

test_freeze_backup_rotation() {
    section "Freeze: backup rotation works on bash 3.2 (no mapfile)"
    fresh_server

    # 8 pre-existing saves, all older than the default 30-day retention
    local i f
    for i in $(seq 1 8); do
        f="$SAVE_DIR/frost_2025010${i}T120000.txt"
        echo "frost_version${d}1" > "$f"
        echo "pane${d}test${d}0${d}1${d}0${d}title${d}:/tmp${d}1" >> "$f"
        touch -t "2025010${i}1200.00" "$f"
    done

    T set-option -g @frost-dir "$SAVE_DIR"

    # Run the real freeze.sh under /bin/bash (macOS ships 3.2, which has
    # no mapfile) against the isolated server
    local plugin_dir out
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    out="$(TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/scripts/freeze.sh" 2>&1)"

    if [[ "$out" != *"mapfile"* ]]; then
        pass "no mapfile error from real freeze.sh"
    else
        fail "mapfile error: $out"
    fi

    local save_file
    save_file="$(readlink "$SAVE_DIR/last" 2>/dev/null)"
    if [ -n "$save_file" ] && [ -f "$SAVE_DIR/$save_file" ]; then
        pass "freeze created a new save file"
    else
        fail "freeze did not create a save file"
    fi

    # 8 old + 1 new = 9; the 5 newest are kept, the rest are >30 days old
    # and must be rotated away → 5 remain
    local remaining
    remaining="$(ls "$SAVE_DIR"/frost_*.txt | wc -l | tr -d ' ')"
    if [ "$remaining" -eq 5 ]; then
        pass "old backups rotated away ($remaining files remain)"
    else
        fail "old backups NOT rotated: $remaining files remain (expected 5)"
    fi
}

test_thaw_rejects_missing_file() {
    section "Thaw validation"

    rm -rf "$SAVE_DIR"
    mkdir -p "$SAVE_DIR"

    local last="$SAVE_DIR/last"

    if [ ! -L "$last" ] && [ ! -f "$last" ]; then
        pass "no save file detected (precondition)"
    else
        fail "unexpected save file exists"
    fi

    # Test with invalid save file (no frost_version header)
    local bad_file="$SAVE_DIR/frost_bad.txt"
    echo "not_a_frost_file" > "$bad_file"
    ln -fs "$(basename "$bad_file")" "$last"

    local first_line
    first_line="$(head -1 "$bad_file")"
    if [[ "$first_line" != frost_version* ]]; then
        pass "invalid save file correctly detected"
    else
        fail "invalid save file not detected"
    fi

    # Unsupported frost_version must be rejected by real thaw.sh
    # Always pin TMUX to the isolated test socket — never touch the default server.
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    local unsupported="$SAVE_DIR/frost_unsupported.txt"
    printf '%s\n' $'frost_version\t9' > "$unsupported"
    ln -fs "$(basename "$unsupported")" "$SAVE_DIR/last"
    if ! TMUX="${SOCKET},$$,0" /bin/bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/thaw.sh" >/dev/null 2>&1; then
        pass "unsupported frost_version rejected"
    else
        fail "unsupported frost_version was accepted"
    fi
}

test_state_line_captures_session() {
    section "State line"
    fresh_server

    local save_file
    save_file="$(do_freeze)"

    local state_line
    state_line="$(grep "^state${d}" "$save_file")"

    if [ -n "$state_line" ]; then
        pass "state line present"
    else
        fail "state line missing"
        return
    fi

    local client_session
    client_session="$(echo "$state_line" | cut -f2)"
    if [ -n "$client_session" ]; then
        pass "client session captured: $client_session"
    else
        pass "client session empty (detached — expected)"
    fi
}

test_auto_save_background_loop() {
    section "Auto-save background loop"

    local dir="$SAVE_DIR/auto_test"
    rm -rf "$dir"
    mkdir -p "$dir"
    local pid_file="$dir/.auto_save.pid"

    # Start a short-lived background loop (1 second interval for testing)
    (
        while true; do
            sleep 1
            echo "tick" >> "$dir/.ticks"
        done
    ) &
    local loop_pid=$!
    echo "$loop_pid" > "$pid_file"

    # Loop should be running
    if kill -0 "$loop_pid" 2>/dev/null; then
        pass "background loop is running"
    else
        fail "background loop not running"
    fi

    # PID file written
    if [ -f "$pid_file" ]; then
        pass "PID file created"
    else
        fail "PID file not created"
    fi

    # PID file contains correct PID
    local stored_pid
    stored_pid="$(cat "$pid_file")"
    if [ "$stored_pid" = "$loop_pid" ]; then
        pass "PID file contains correct PID"
    else
        fail "PID file has '$stored_pid', expected '$loop_pid'"
    fi

    # Duplicate detection: check PID is still alive
    if kill -0 "$stored_pid" 2>/dev/null; then
        pass "duplicate check: existing loop detected as alive"
    else
        fail "duplicate check: existing loop not detected"
    fi

    # Wait for at least one tick
    sleep 1.5
    if [ -f "$dir/.ticks" ]; then
        pass "loop executed at least one tick"
    else
        fail "loop did not tick"
    fi

    # Clean shutdown
    kill "$loop_pid" 2>/dev/null
    wait "$loop_pid" 2>/dev/null || true

    if ! kill -0 "$loop_pid" 2>/dev/null; then
        pass "loop stopped after kill"
    else
        fail "loop still running after kill"
    fi
}

test_locking() {
    section "Locking"

    rm -rf "$SAVE_DIR"
    mkdir -p "$SAVE_DIR"

    if command -v flock >/dev/null 2>&1; then
        local lock_file="$SAVE_DIR/.frost.lock"

        # Take the lock in a subshell that holds it
        (
            exec 9>"$lock_file"
            flock -n 9
            sleep 2
        ) &
        local holder_pid=$!
        sleep 0.2

        # Try to acquire — should fail
        if (exec 9>"$lock_file"; flock -n 9) 2>/dev/null; then
            fail "lock was acquired while held (should have failed)"
        else
            pass "concurrent lock correctly blocked"
        fi

        wait "$holder_pid" 2>/dev/null
        sleep 0.1

        if (exec 9>"$lock_file"; flock -n 9); then
            pass "lock acquired after release"
        else
            fail "lock not acquired after release"
        fi
    else
        # Test directory-based locking when flock is unavailable.
        local lock_dir="$SAVE_DIR/.frost.lock.d"

        # Take the lock in a subshell that holds it
        (
            mkdir "$lock_dir" 2>/dev/null
            echo "$$" > "$lock_dir/pid"
            sleep 2
            rm -rf "$lock_dir"
        ) &
        local holder_pid=$!
        sleep 0.2

        # Try to acquire — should fail (directory already exists)
        if mkdir "$lock_dir" 2>/dev/null; then
            fail "directory lock was acquired while held (should have failed)"
            rm -rf "$lock_dir"
        else
            pass "concurrent directory lock correctly blocked"
        fi

        wait "$holder_pid" 2>/dev/null
        sleep 0.1

        # Now should succeed
        if mkdir "$lock_dir" 2>/dev/null; then
            pass "directory lock acquired after release"
            rm -rf "$lock_dir"
        else
            fail "directory lock not acquired after release"
        fi
    fi
}

test_idempotent_save() {
    section "Idempotent save (dedup)"
    fresh_server

    # Wait for pane title to settle (tmux updates it asynchronously)
    sleep 0.5

    local save1 save2
    save1="$(do_freeze)"
    save2="$(do_freeze)"

    # Compare structural content (strip pane titles which tmux updates async)
    local struct1 struct2
    struct1="$(grep -v "^state" "$save1" | cut -f1-5,7-8)"
    struct2="$(grep -v "^state" "$save2" | cut -f1-5,7-8)"

    if [ "$struct1" = "$struct2" ]; then
        pass "identical saves produce identical structural content"
    else
        fail "identical saves differ structurally"
    fi
}

test_thaw_empty_pane_title() {
    section "Thaw: empty pane_title (TUI app) keeps pane cwd"
    fresh_server

    # A TUI app may clear the pane title, leaving an empty field in the
    # save file. Field parsing must not collapse the consecutive tabs —
    # otherwise dir shifts and the pane respawns in the server's cwd.
    local bi pi p1 p2
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    p1=$pi
    p2=$((pi + 1))
    local save_file="$SAVE_DIR/frost_empty_title.txt"
    {
        echo "frost_version${d}1"
        echo "pane${d}restored${d}${bi}${d}1${d}${p1}${d}${d}:/tmp${d}1"
        echo "pane${d}restored${d}${bi}${d}1${d}${p2}${d}Some Title${d}:/usr${d}0"
        echo "window${d}restored${d}${bi}${d}:zsh${d}1${d}:*${d}tiled${d}:"
        echo "state${d}restored${d}"
    } > "$save_file"
    ln -fs "$(basename "$save_file")" "$SAVE_DIR/last"

    T set-option -g @frost-dir "$SAVE_DIR"

    # Run the real thaw.sh against the isolated server via $TMUX
    local plugin_dir
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    TMUX="${SOCKET},$$,0" "$plugin_dir/scripts/thaw.sh" >/dev/null 2>&1
    sleep 1

    local cwd1 cwd2
    cwd1="$(T display-message -t "restored:${bi}.${p1}" -p '#{pane_current_path}' 2>/dev/null)"
    cwd2="$(T display-message -t "restored:${bi}.${p2}" -p '#{pane_current_path}' 2>/dev/null)"

    if [ "$cwd1" = "/tmp" ] || [ "$cwd1" = "/private/tmp" ]; then
        pass "empty-title pane restored to saved cwd ($cwd1)"
    else
        fail "empty-title pane cwd: '$cwd1' (expected /tmp)"
    fi

    if [ "$cwd2" = "/usr" ]; then
        pass "titled pane restored to saved cwd ($cwd2)"
    else
        fail "titled pane cwd: '$cwd2' (expected /usr)"
    fi
}

test_thaw_idempotent() {
    section "Thaw: idempotent over existing sessions"
    fresh_server

    # Re-thawing over existing sessions must reuse panes (respawn) instead
    # of splitting new ones — pane count and topology stay stable.
    local bi pi
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    local p1=$pi p2=$((pi + 1)) p3=$((pi + 2))
    local save_file="$SAVE_DIR/frost_idem.txt"
    {
        echo "frost_version${d}1"
        echo "pane${d}${SESSION}${d}${bi}${d}1${d}${p1}${d}t1${d}:/tmp${d}1"
        echo "pane${d}${SESSION}${d}${bi}${d}1${d}${p2}${d}t2${d}:/usr${d}0"
        echo "pane${d}${SESSION}${d}${bi}${d}1${d}${p3}${d}t3${d}:/etc${d}0"
        echo "window${d}${SESSION}${d}${bi}${d}:zsh${d}1${d}:*${d}tiled${d}:"
        echo "state${d}${SESSION}${d}"
    } > "$save_file"
    ln -fs "$(basename "$save_file")" "$SAVE_DIR/last"

    T set-option -g @frost-dir "$SAVE_DIR"

    local plugin_dir
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    # 1st thaw over the already-existing session
    TMUX="${SOCKET},$$,0" "$plugin_dir/scripts/thaw.sh" >/dev/null 2>&1
    sleep 1
    local count1 snap1
    count1="$(pane_count "${SESSION}:${bi}")"
    snap1="$(T list-panes -t "${SESSION}:${bi}" -F '#{pane_index} #{pane_current_path}' | sort -n)"

    # 2nd thaw — must not duplicate panes
    TMUX="${SOCKET},$$,0" "$plugin_dir/scripts/thaw.sh" >/dev/null 2>&1
    sleep 1
    local count2 snap2
    count2="$(pane_count "${SESSION}:${bi}")"
    snap2="$(T list-panes -t "${SESSION}:${bi}" -F '#{pane_index} #{pane_current_path}' | sort -n)"

    if [ "$count1" -eq 3 ]; then
        pass "1st thaw: window has 3 panes"
    else
        fail "1st thaw: window has $count1 panes (expected 3)"
    fi

    if [ "$count2" -eq "$count1" ]; then
        pass "2nd thaw: pane count stable ($count2)"
    else
        fail "2nd thaw: pane count grew $count1 -> $count2"
    fi

    if [ "$snap1" = "$snap2" ]; then
        pass "2nd thaw: pane topology identical"
    else
        fail "2nd thaw: topology changed"
    fi

    # First saved pane must land on its own index with its own cwd
    local first_cwd
    first_cwd="$(T display-message -t "${SESSION}:${bi}.${p1}" -p '#{pane_current_path}' 2>/dev/null)"
    if [ "$first_cwd" = "/tmp" ] || [ "$first_cwd" = "/private/tmp" ]; then
        pass "first pane respawned at its own index ($first_cwd)"
    else
        fail "first pane cwd: '$first_cwd' (expected /tmp)"
    fi
}

test_multiple_cycles() {
    section "Multiple save/restore cycles"
    fresh_server

    T split-window -t "$SESSION"
    T split-window -t "$SESSION"
    T select-layout -t "$SESSION" tiled

    local save_file
    for _ in 1 2 3; do
        save_file="$(do_freeze)"
        T kill-server 2>/dev/null || true
        sleep 0.1
        do_thaw "$save_file"
        do_apply_layouts "$save_file"
    done

    local final_panes
    final_panes="$(pane_count "$SESSION")"
    if [ "$final_panes" -eq 3 ]; then
        pass "3 cycles: pane count stable (3)"
    else
        fail "3 cycles: pane count drifted to $final_panes (expected 3)"
    fi

    # Check no panes are stacked
    local any_stacked=false
    while IFS=$'\t' read -r h; do
        if [ "$h" -le 1 ] 2>/dev/null; then any_stacked=true; fi
    done < <(T list-panes -t "$SESSION" -F "#{pane_height}")

    if [ "$any_stacked" = "false" ]; then
        pass "3 cycles: no stacked panes"
    else
        fail "3 cycles: stacked panes detected"
    fi
}


test_thaw_confirm() {
    section "Optional thaw confirm (@frost-thaw-confirm)"
    local plugin_dir real_tmux
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # Absolute path before any tmux() override — needed by the confirm spy.
    real_tmux="$(type -P tmux)"
    if [ -z "$real_tmux" ] || [ ! -x "$real_tmux" ]; then
        fail "could not resolve real tmux binary"
        return
    fi
    # shellcheck source=../scripts/helpers.sh
    source "$plugin_dir/scripts/helpers.sh"

    # Keep helpers' tmux calls on the isolated socket for this section.
    tmux() { command tmux -S "$SOCKET" "$@"; }

    # ── Gate: option unset / off never confirms ─────────────────────
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    T split-window -t "$SESSION"
    T set-option -gu @frost-thaw-confirm 2>/dev/null || true
    if frost_thaw_needs_confirm; then
        fail "unset option: needs_confirm unexpectedly true"
    else
        pass "unset option: no confirm even with multi-pane"
    fi

    T set-option -g @frost-thaw-confirm "off"
    if frost_thaw_needs_confirm; then
        fail "off: needs_confirm unexpectedly true"
    else
        pass "off: no confirm even with multi-pane"
    fi

    # ── Gate: on + every session exactly 1 pane → no confirm ────────
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "on"
    TMUX="" T new-session -d -s "one-pane-b"
    if frost_thaw_needs_confirm; then
        fail "on + all 1-pane sessions: needs_confirm true"
    else
        pass "on + all 1-pane sessions: no confirm"
    fi

    # ── Gate: on + one multi-pane session → confirm (server-wide) ───
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "on"
    T split-window -t "$SESSION"
    TMUX="" T new-session -d -s "solo"
    # Client-facing session is solo (1 pane), but server has multi-pane SESSION
    if frost_thaw_needs_confirm; then
        pass "on + any multi-pane session: confirm (server-wide)"
    else
        fail "on + multi-pane elsewhere: needs_confirm false"
    fi

    # ── Dynamic option reload ───────────────────────────────────────
    T set-option -g @frost-thaw-confirm "off"
    if frost_thaw_needs_confirm; then
        fail "reload off: still needs confirm"
    else
        pass "reload off→ next check skips confirm"
    fi
    T set-option -g @frost-thaw-confirm "on"
    if frost_thaw_needs_confirm; then
        pass "reload on→ next check requires confirm"
    else
        fail "reload on: needs_confirm false"
    fi

    # ── Binding points at thaw-key.sh ───────────────────────────────
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-auto-save-interval "0"
    T set-option -g @frost-auto-restore "off"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/glacier.tmux" >/dev/null 2>&1
    local bind_line
    bind_line="$(T list-keys -T prefix | grep 'C-r' || true)"
    if echo "$bind_line" | grep -q "thaw-key.sh"; then
        pass "restore key binds thaw-key.sh"
    else
        fail "restore key binding missing thaw-key.sh: $bind_line"
    fi
    if echo "$bind_line" | grep -qE 'force|thaw-force'; then
        fail "unexpected force binding present"
    else
        pass "no force-key binding added"
    fi

    local bi pi save_file
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    save_file="$SAVE_DIR/frost_confirm.txt"

    write_confirm_fixture() {
        mkdir -p "$SAVE_DIR"
        {
            echo "frost_version${d}2"
            echo "pane${d}${SESSION}${d}${bi}${d}1${d}${pi}${d}t${d}:/tmp${d}1"
            echo "pane${d}thawed-extra${d}${bi}${d}1${d}${pi}${d}t${d}:/tmp${d}1"
            echo "window${d}${SESSION}${d}${bi}${d}:zsh${d}1${d}:*${d}tiled${d}:"
            echo "window${d}thawed-extra${d}${bi}${d}:zsh${d}1${d}:*${d}tiled${d}:"
            echo "state${d}${SESSION}${d}"
        } > "$save_file"
        ln -fs "$(basename "$save_file")" "$SAVE_DIR/last"
    }

    # ── off + multi-pane: thaw-key runs thaw with no prompt ─────────
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    write_confirm_fixture
    T split-window -t "$SESSION"
    T set-option -g @frost-thaw-confirm "off"
    local before_sessions after_sessions
    before_sessions="$(T list-sessions -F '#{session_name}' | sort | tr '\n' ',')"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/scripts/thaw-key.sh" >/dev/null 2>&1
    sleep 1
    after_sessions="$(T list-sessions -F '#{session_name}' | sort | tr '\n' ',')"
    if echo "$after_sessions" | grep -q "thawed-extra"; then
        pass "off + multi-pane: thaw-key restored without prompt"
    else
        fail "off + multi-pane: thaw did not run (before=$before_sessions after=$after_sessions)"
    fi

    # ── on + all 1-pane: thaw-key restores without prompt ───────────
    fresh_server
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "on"
    write_confirm_fixture
    TMUX="" T new-session -d -s "other-one"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/scripts/thaw-key.sh" >/dev/null 2>&1
    sleep 1
    if T has-session -t "thawed-extra" 2>/dev/null; then
        pass "on + all 1-pane: thaw-key restored without prompt"
    else
        fail "on + all 1-pane: thaw did not run"
    fi

    # ── on + multi-pane: confirm accept / reject via tmux spy ───────
    fresh_server
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "on"
    write_confirm_fixture
    T split-window -t "$SESSION"

    local spy_dir confirm_log
    spy_dir="$SAVE_DIR/tmux-spy"
    confirm_log="$SAVE_DIR/confirm.log"
    mkdir -p "$spy_dir"
    rm -f "$confirm_log"
    cat > "$spy_dir/tmux" << SPY
#!/bin/bash
# Spy matches real confirm-before: the prompt is scheduled, and the command
# argument runs only on accept. thaw-key must not treat our exit status as
# an in-process decline or as a signal to exec thaw.sh itself.
if [ "\${1:-}" = "confirm-before" ]; then
  printf '%s\n' "\$*" >> "$confirm_log"
  if [ "\${FROST_TEST_CONFIRM:-}" = "accept" ]; then
    shift
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "-p" ]; then
        shift 2
        continue
      fi
      break
    done
    # confirm-before keeps one command string and parses it on y.
    # Passing that string as a single argv is "unknown command".
    if [ \$# -eq 1 ]; then
      eval "set -- \$1"
    fi
    exec "$real_tmux" -S "$SOCKET" "\$@"
  fi
  # Decline: command is not run. Non-zero matches a cancelled prompt.
  exit 1
fi
exec "$real_tmux" -S "$SOCKET" "\$@"
SPY
    chmod +x "$spy_dir/tmux"

    # Reject: sessions unchanged, confirm called once, thaw-key exits 0
    local sessions_before panes_before reject_rc
    sessions_before="$(T list-sessions -F '#{session_name}' | sort | tr '\n' ',')"
    panes_before="$(T list-panes -a | wc -l | tr -d ' ')"
    set +e
    FROST_TEST_CONFIRM=reject PATH="$spy_dir:$PATH" TMUX="${SOCKET},$$,0" \
        /bin/bash "$plugin_dir/scripts/thaw-key.sh" >/dev/null 2>&1
    reject_rc=$?
    set -e
    sleep 0.3
    local sessions_after panes_after confirm_count
    sessions_after="$(T list-sessions -F '#{session_name}' | sort | tr '\n' ',')"
    panes_after="$(T list-panes -a | wc -l | tr -d ' ')"
    confirm_count=0
    [ -f "$confirm_log" ] && confirm_count="$(wc -l < "$confirm_log" | tr -d ' ')"
    if [ "$confirm_count" -eq 1 ]; then
        pass "on + multi-pane: confirm-before exactly once (reject path)"
    else
        fail "on + multi-pane reject: confirm count=$confirm_count (expected 1)"
    fi
    if grep -q '(y/n)' "$confirm_log" 2>/dev/null; then
        pass "confirm prompt includes (y/n)"
    else
        fail "confirm prompt missing (y/n): $(tr '\\n' ' ' < "$confirm_log" 2>/dev/null || true)"
    fi
    if [ "$reject_rc" -eq 0 ]; then
        pass "confirm rejected: thaw-key exits 0 (silent cancel)"
    else
        fail "confirm rejected: thaw-key exited $reject_rc (expected 0)"
    fi
    if [ "$sessions_before" = "$sessions_after" ] && [ "$panes_before" = "$panes_after" ] \
        && ! T has-session -t "thawed-extra" 2>/dev/null; then
        pass "confirm rejected: no session/pane changes"
    else
        fail "confirm rejected: state changed ($sessions_before -> $sessions_after, panes $panes_before -> $panes_after)"
    fi
    if grep -q 'run-shell' "$confirm_log" 2>/dev/null && grep -q 'thaw\.sh' "$confirm_log" 2>/dev/null; then
        pass "confirm schedules run-shell of thaw.sh (not an in-process decline)"
    else
        fail "confirm command missing run-shell thaw.sh: $(tr '\\n' ' ' < "$confirm_log" 2>/dev/null || true)"
    fi
    if grep -q 'thaw skipped — user declined confirm' "$SAVE_DIR"/frost_*.log 2>/dev/null; then
        fail "confirm rejected: treated confirm-before status as in-process decline"
    else
        pass "confirm rejected: no in-process decline log"
    fi
    if grep -q 'thaw started' "$SAVE_DIR"/frost_*.log 2>/dev/null; then
        fail "confirm rejected: thaw started anyway"
    else
        pass "confirm rejected: thaw.sh was not run"
    fi

    # Accept: thaw runs once
    rm -f "$confirm_log"
    local accept_rc
    set +e
    FROST_TEST_CONFIRM=accept PATH="$spy_dir:$PATH" TMUX="${SOCKET},$$,0" \
        /bin/bash "$plugin_dir/scripts/thaw-key.sh" >/dev/null 2>&1
    accept_rc=$?
    set -e
    local i=0 thaw_starts=0
    while [ "$i" -lt 20 ]; do
        if T has-session -t "thawed-extra" 2>/dev/null; then
            break
        fi
        sleep 0.25
        i=$((i + 1))
    done
    # run-shell is asynchronous; give the log line a moment after the session exists
    sleep 0.3
    confirm_count=0
    [ -f "$confirm_log" ] && confirm_count="$(wc -l < "$confirm_log" | tr -d ' ')"
    if [ "$confirm_count" -eq 1 ]; then
        pass "on + multi-pane: confirm-before exactly once (accept path)"
    else
        fail "on + multi-pane accept: confirm count=$confirm_count (expected 1)"
    fi
    thaw_starts="$(grep -c 'thaw started' "$SAVE_DIR"/frost_*.log 2>/dev/null || true)"
    thaw_starts="${thaw_starts:-0}"
    if T has-session -t "thawed-extra" 2>/dev/null && [ "$thaw_starts" -eq 1 ]; then
        pass "confirm accepted: scheduled command thawed once"
    else
        fail "confirm accepted: thaw starts=$thaw_starts (expected 1) thawed-extra=$(T has-session -t thawed-extra 2>/dev/null && echo yes || echo no)"
    fi
    if [ "$accept_rc" -eq 0 ]; then
        pass "confirm accepted: thaw-key exits 0 after scheduling confirm"
    else
        fail "confirm accepted: thaw-key exited $accept_rc (expected 0)"
    fi

    # ── auto-restore never prompts ──────────────────────────────────
    if grep -q 'thaw-key.sh' "$plugin_dir/scripts/auto-restore.sh"; then
        fail "auto-restore.sh must not call thaw-key.sh"
    else
        pass "auto-restore.sh does not reference thaw-key.sh"
    fi
    if grep -q 'thaw\.sh' "$plugin_dir/scripts/auto-restore.sh"; then
        pass "auto-restore.sh still invokes thaw.sh directly"
    else
        fail "auto-restore.sh missing thaw.sh invocation"
    fi

    fresh_server
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "on"
    write_confirm_fixture
    rm -f "$confirm_log"
    # Fresh server has 1 pane → auto-restore should thaw with no confirm
    FROST_TEST_CONFIRM=reject PATH="$spy_dir:$PATH" TMUX="${SOCKET},$$,0" \
        /bin/bash "$plugin_dir/scripts/auto-restore.sh" "$plugin_dir" >/dev/null 2>&1 || true
    sleep 1
    if [ -f "$confirm_log" ]; then
        fail "auto-restore invoked confirm-before with option on"
    else
        pass "auto-restore with option on: no confirm-before"
    fi
    if T has-session -t "thawed-extra" 2>/dev/null; then
        pass "auto-restore still thaws on fresh server"
    else
        fail "auto-restore did not thaw on fresh server"
    fi

    # Non-fresh server: auto-restore must skip (existing multi-pane)
    fresh_server
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "on"
    write_confirm_fixture
    T split-window -t "$SESSION"
    local sessions_pre
    sessions_pre="$(T list-sessions -F '#{session_name}' | sort | tr '\n' ',')"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/scripts/auto-restore.sh" "$plugin_dir" >/dev/null 2>&1 || true
    sleep 0.3
    if T has-session -t "thawed-extra" 2>/dev/null; then
        fail "auto-restore ran on non-fresh server"
    else
        pass "auto-restore fresh-only condition preserved"
    fi
    local sessions_post
    sessions_post="$(T list-sessions -F '#{session_name}' | sort | tr '\n' ',')"
    if [ "$sessions_pre" = "$sessions_post" ]; then
        pass "non-fresh auto-restore: sessions unchanged"
    else
        fail "non-fresh auto-restore changed sessions"
    fi

    # ── frost_version header still accepted via thaw-key off path ───
    fresh_server
    bi="$(base_idx)"
    pi="$(T show -gv pane-base-index 2>/dev/null || echo 0)"
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-thaw-confirm "off"
    local v2="$SAVE_DIR/frost_v2_confirm.txt"
    {
        echo "frost_version${d}2"
        echo "pane${d}v2sess${d}${bi}${d}1${d}${pi}${d}t${d}:/tmp${d}1"
        echo "window${d}v2sess${d}${bi}${d}:zsh${d}1${d}:*${d}tiled${d}:"
        echo "state${d}v2sess${d}"
    } > "$v2"
    ln -fs "$(basename "$v2")" "$SAVE_DIR/last"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/scripts/thaw-key.sh" >/dev/null 2>&1
    sleep 1
    if T has-session -t "v2sess" 2>/dev/null; then
        pass "frost_version 2 save still thaws via key path"
    else
        fail "frost_version 2 thaw via key path failed"
    fi

    unset -f tmux
}


test_auto_save_server_exit() {
    section "Auto-save shutdown on server exit"
    local plugin_dir pid_file meta_file loop_pid new_loop_pid server_pid retries child children
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-auto-restore off
    T set-option -g @frost-auto-save-interval 60
    pid_file="$SAVE_DIR/.auto_save.pid"
    meta_file="$SAVE_DIR/.auto_save.meta"
    T run-shell "'$plugin_dir/glacier.tmux'"
    loop_pid="$(cat "$pid_file")"
    sleep 0.2
    T kill-server
    # Start a new server on the same socket immediately and check whether it reuses the old loop.
    T -f /dev/null new-session -d -s "$SESSION" -x 200 -y 50
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-auto-restore off
    T set-option -g @frost-auto-save-interval 60
    T run-shell "'$plugin_dir/glacier.tmux'"
    new_loop_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$new_loop_pid" ] && [ "$new_loop_pid" != "$loop_pid" ] && kill -0 "$new_loop_pid" 2>/dev/null; then
        pass "New server on the same socket starts a new auto-save loop"
    else
        fail "New server reused the previous server's auto-save loop"
    fi
    retries=0
    while kill -0 "$loop_pid" 2>/dev/null && [ "$retries" -lt 30 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done
    if ! kill -0 "$loop_pid" 2>/dev/null; then
        pass "Loop exits within 3 seconds of server exit even with a 60-minute save interval"
    else
        fail "Auto-save loop is still running after server exit"
        children="$(pgrep -P "$loop_pid" 2>/dev/null || true)"
        kill "$loop_pid" 2>/dev/null || true
        for child in $children; do kill "$child" 2>/dev/null || true; done
    fi
    if [ -n "$new_loop_pid" ] && [ "$(cat "$pid_file" 2>/dev/null)" = "$new_loop_pid" ] && [ -f "$meta_file" ]; then
        pass "New loop's files survive the previous server's loop exit"
    else
        fail "Previous server's loop removed the new loop's files"
    fi
    T kill-server
    retries=0
    while [ -n "$new_loop_pid" ] && kill -0 "$new_loop_pid" 2>/dev/null && [ "$retries" -lt 30 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done
    if [ -n "$new_loop_pid" ] && kill -0 "$new_loop_pid" 2>/dev/null; then
        fail "Auto-save loop remains after the new server exits"
        children="$(pgrep -P "$new_loop_pid" 2>/dev/null || true)"
        kill "$new_loop_pid" 2>/dev/null || true
        for child in $children; do kill "$child" 2>/dev/null || true; done
    fi
    if [ ! -e "$pid_file" ] && [ ! -e "$meta_file" ]; then
        pass "Exited loop's PID and metadata files are removed"
    else
        fail "Exited loop's PID or metadata file remains"
    fi

    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    server_pid="$(T display-message -p '#{pid}')"
    "$plugin_dir/scripts/auto_save_loop.sh" "$pid_file" 1 "$plugin_dir/scripts/freeze.sh" "$SOCKET" "$server_pid" &
    loop_pid=$!
    printf '%s\n' "$loop_pid" >"$pid_file"
    printf 'original metadata\n' >"$meta_file"
    retries=0
    while [ ! -e "$SAVE_DIR/last" ] && [ "$retries" -lt 40 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done
    if [ -e "$SAVE_DIR/last" ]; then
        pass "Live server runs freeze at the configured interval"
    else
        fail "Auto-save failed to save while the server was running"
    fi
    # Simulate a new loop taking ownership of the same files.
    printf '%s\n' "$$" >"$pid_file"
    printf 'successor metadata\n' >"$meta_file"
    T kill-server
    retries=0
    while kill -0 "$loop_pid" 2>/dev/null && [ "$retries" -lt 30 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done
    if ! kill -0 "$loop_pid" 2>/dev/null; then
        pass "Directly launched auto-save loop also exits when the server stops"
    else
        fail "Directly launched auto-save loop remains after server exit"
        children="$(pgrep -P "$loop_pid" 2>/dev/null || true)"
        kill "$loop_pid" 2>/dev/null || true
        for child in $children; do kill "$child" 2>/dev/null || true; done
    fi
    wait "$loop_pid" 2>/dev/null || true
    if [ "$(cat "$pid_file" 2>/dev/null)" = "$$" ] && [ "$(cat "$meta_file" 2>/dev/null)" = 'successor metadata' ]; then
        pass "Preserve PID and metadata files owned by the successor loop"
    else
        fail "Previous loop deleted its successor's files"
    fi
}

test_auto_save_restart_on_script_change() {
    section "Auto-save restart on script fingerprint / path change"
    local plugin_dir
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    # shellcheck source=../scripts/helpers.sh
    source "$plugin_dir/scripts/helpers.sh"

    # Keep helpers' tmux calls on the isolated socket for this section.
    tmux() { command tmux -S "$SOCKET" "$@"; }

    fresh_server
    T set-option -g @frost-dir "$SAVE_DIR"
    T set-option -g @frost-auto-save-interval "60"
    T set-option -g @frost-auto-restore "off"

    local pid_file="$SAVE_DIR/.auto_save.pid"
    local meta_file="$SAVE_DIR/.auto_save.meta"
    local loop_script="$plugin_dir/scripts/auto_save_loop.sh"
    local freeze_script="$plugin_dir/scripts/freeze.sh"

    # ── Helper unit checks ─────────────────────────────────────────
    local fp
    fp="$(frost_script_fingerprint "$freeze_script")"
    if [[ "$fp" == *:* ]] && [ -n "${fp%%:*}" ] && [ -n "${fp#*:}" ]; then
        pass "frost_script_fingerprint returns inode:mtime"
    else
        fail "frost_script_fingerprint unexpected: '$fp'"
    fi

    write_auto_save_meta "$meta_file" "$loop_script" "$freeze_script"
    if auto_save_meta_matches "$meta_file" "$loop_script" "$freeze_script"; then
        pass "auto_save_meta_matches: fresh meta matches"
    else
        fail "auto_save_meta_matches: fresh meta should match"
    fi
    if auto_save_meta_matches "$meta_file" "/tmp/other-loop.sh" "$freeze_script"; then
        fail "auto_save_meta_matches: path mismatch should fail"
    else
        pass "auto_save_meta_matches: path mismatch detected"
    fi
    # Stale fingerprint in meta
    printf '%s\n' "loop_path=${loop_script}" "loop_fp=0:0" \
        "freeze_path=${freeze_script}" "freeze_fp=0:0" > "$meta_file"
    if auto_save_meta_matches "$meta_file" "$loop_script" "$freeze_script"; then
        fail "auto_save_meta_matches: stale fp should fail"
    else
        pass "auto_save_meta_matches: stale fingerprint detected"
    fi
    if auto_save_meta_matches "$SAVE_DIR/.missing.meta" "$loop_script" "$freeze_script"; then
        fail "auto_save_meta_matches: missing meta should fail"
    else
        pass "auto_save_meta_matches: missing meta fails"
    fi
    rm -f "$meta_file"

    # ── Load plugin: start loop + write meta ─────────────────────
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/glacier.tmux" >/dev/null 2>&1
    sleep 0.4

    local pid1
    if [ -f "$pid_file" ]; then
        pid1="$(cat "$pid_file")"
        pass "auto-save pid file created after load"
    else
        fail "auto-save pid file missing after load"
        unset -f tmux
        return
    fi
    if kill -0 "$pid1" 2>/dev/null &&
        ps -p "$pid1" -o args= 2>/dev/null | grep -q "auto_save_loop"; then
        pass "auto-save loop running after load (pid $pid1)"
    else
        fail "auto-save loop not running after load (pid '$pid1')"
        unset -f tmux
        return
    fi
    if [ -f "$meta_file" ] && auto_save_meta_matches "$meta_file" "$loop_script" "$freeze_script"; then
        pass "auto-save meta written and matches current scripts"
    else
        fail "auto-save meta missing or mismatch after load: $(tr '\\n' ' ' < "$meta_file" 2>/dev/null || true)"
    fi

    # ── Unchanged reload: no PID churn ─────────────────────────────
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/glacier.tmux" >/dev/null 2>&1
    sleep 0.3
    local pid2
    pid2="$(cat "$pid_file" 2>/dev/null || true)"
    if [ "$pid1" = "$pid2" ] && kill -0 "$pid1" 2>/dev/null; then
        pass "unchanged fingerprint reload: same pid (no churn)"
    else
        fail "unchanged fingerprint reload: pid churn ($pid1 -> $pid2)"
    fi

    # ── Stale fingerprint in meta → restart ────────────────────────
    printf '%s\n' "loop_path=${loop_script}" "loop_fp=0:0" \
        "freeze_path=${freeze_script}" "freeze_fp=0:0" > "$meta_file"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/glacier.tmux" >/dev/null 2>&1
    sleep 0.4
    local pid3
    pid3="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid3" ] && [ "$pid3" != "$pid1" ]; then
        pass "stale fingerprint: new loop pid ($pid1 -> $pid3)"
    else
        fail "stale fingerprint: expected new pid (still $pid3)"
    fi
    if ! kill -0 "$pid1" 2>/dev/null; then
        pass "stale fingerprint: old loop stopped"
    else
        fail "stale fingerprint: old loop still alive (pid $pid1)"
        kill "$pid1" 2>/dev/null || true
    fi
    if auto_save_meta_matches "$meta_file" "$loop_script" "$freeze_script"; then
        pass "stale fingerprint: meta rewritten to current scripts"
    else
        fail "stale fingerprint: meta not rewritten"
    fi

    # ── In-place mtime change (git pull simulation) → restart ──────
    local pid_before_touch="$pid3"
    # Ensure mtime advances (some FS have 1s resolution)
    sleep 1
    touch "$freeze_script"
    TMUX="${SOCKET},$$,0" /bin/bash "$plugin_dir/glacier.tmux" >/dev/null 2>&1
    sleep 0.4
    local pid4
    pid4="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid4" ] && [ "$pid4" != "$pid_before_touch" ]; then
        pass "freeze.sh mtime change: loop restarted ($pid_before_touch -> $pid4)"
    else
        fail "freeze.sh mtime change: pid unchanged ($pid_before_touch)"
    fi
    if ! kill -0 "$pid_before_touch" 2>/dev/null; then
        pass "freeze.sh mtime change: old loop stopped"
    else
        fail "freeze.sh mtime change: old loop still alive"
        kill "$pid_before_touch" 2>/dev/null || true
    fi

    # ── Path change via alternate plugin copy → restart ────────────
    local alt_plugin pid_before_path
    alt_plugin="$SAVE_DIR/alt-plugin"
    pid_before_path="$pid4"
    rm -rf "$alt_plugin"
    mkdir -p "$alt_plugin/scripts"
    cp "$plugin_dir/glacier.tmux" "$alt_plugin/"
    cp "$plugin_dir/scripts/"*.sh "$alt_plugin/scripts/"
    TMUX="${SOCKET},$$,0" /bin/bash "$alt_plugin/glacier.tmux" >/dev/null 2>&1
    sleep 0.4
    local pid5
    pid5="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid5" ] && [ "$pid5" != "$pid_before_path" ]; then
        pass "plugin path change: loop restarted ($pid_before_path -> $pid5)"
    else
        fail "plugin path change: pid unchanged ($pid_before_path)"
    fi
    if ! kill -0 "$pid_before_path" 2>/dev/null; then
        pass "plugin path change: old loop stopped"
    else
        fail "plugin path change: old loop still alive"
        kill "$pid_before_path" 2>/dev/null || true
    fi
    local alt_loop="$alt_plugin/scripts/auto_save_loop.sh"
    local alt_freeze="$alt_plugin/scripts/freeze.sh"
    if auto_save_meta_matches "$meta_file" "$alt_loop" "$alt_freeze"; then
        pass "plugin path change: meta points at alternate plugin scripts"
    else
        fail "plugin path change: meta mismatch for alt plugin: $(tr '\\n' ' ' < "$meta_file" 2>/dev/null || true)"
    fi
    # New loop's argv should reference the alt freeze path
    if ps -p "$pid5" -o args= 2>/dev/null | grep -q "$alt_freeze"; then
        pass "new loop argv uses alternate freeze.sh"
    else
        # nohup/setsid may shorten args; check meta freeze_path instead as soft pass note
        local meta_freeze
        meta_freeze="$(grep '^freeze_path=' "$meta_file" | cut -d= -f2-)"
        if [ "$meta_freeze" = "$alt_freeze" ]; then
            pass "new loop meta freeze_path is alternate freeze.sh (argv truncated)"
        else
            fail "new loop not bound to alternate freeze.sh (args=$(ps -p "$pid5" -o args= 2>/dev/null))"
        fi
    fi

    # ── Missing meta with live loop → restart ──────────────────────
    local pid_before_missing="$pid5"
    rm -f "$meta_file"
    TMUX="${SOCKET},$$,0" /bin/bash "$alt_plugin/glacier.tmux" >/dev/null 2>&1
    sleep 0.4
    local pid6
    pid6="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid6" ] && [ "$pid6" != "$pid_before_missing" ]; then
        pass "missing meta: loop restarted ($pid_before_missing -> $pid6)"
    else
        fail "missing meta: expected restart (pid $pid_before_missing -> $pid6)"
    fi
    if [ -f "$meta_file" ]; then
        pass "missing meta: meta rewritten after restart"
    else
        fail "missing meta: meta not rewritten"
    fi

    # Cleanup loop so later tests are not affected by long-interval daemon
    if [ -n "$pid6" ]; then
        kill "$pid6" 2>/dev/null || true
        wait "$pid6" 2>/dev/null || true
    fi
    rm -f "$pid_file" "$meta_file"
    # Disable for subsequent glacier.tmux loads in other tests
    T set-option -g @frost-auto-save-interval "0"

    unset -f tmux
}


# ════════════════════════════════════════════════════════════════════
# Runner
# ════════════════════════════════════════════════════════════════════

echo -e "${YELLOW}tmux-glacier test suite${NC}"
echo "socket: $SOCKET"
echo "save dir: $SAVE_DIR"

test_save_file_format
test_last_symlink
test_layout_validation
test_round_trip_single_session
test_round_trip_multi_window
test_round_trip_multi_session
test_window_names_restored
test_pane_cwd_captured
test_backup_retention
test_freeze_backup_rotation
test_thaw_rejects_missing_file
test_state_line_captures_session
test_thaw_empty_pane_title
test_thaw_idempotent
test_auto_save_background_loop
test_auto_save_restart_on_script_change
test_auto_save_server_exit
test_locking
test_idempotent_save
test_multiple_cycles
test_thaw_confirm

if /bin/bash "$(dirname "${BASH_SOURCE[0]}")/pane_user_options_tests.sh"; then
    pass "pane user option integration tests"
else
    fail "pane user option integration tests"
fi

echo ""
echo -e "${YELLOW}── Summary ──${NC}"
echo -e "  ${GREEN}Passed${NC}: $PASS_COUNT"
echo -e "  ${RED}Failed${NC}: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
