#!/usr/bin/env bash
#
# pane_user_options.sh — pane-local @* option codec and enumeration helpers.
# Sourced by freeze.sh and thaw.sh after helpers.sh.
#

# Determine the Base64 decoder options to use at runtime once.
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

# Remove platform-specific line breaks while preserving the encoder's exit status.
encode_base64() (
  set -o pipefail
  base64 | tr -d '\r\n'
)

# Emit the original bytes only after decoding succeeds completely.
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

# Protect only the final semicolon in tmux argv from command separation.
escape_tmux_argument() {
  local __glacier_argument="$1"
  case "$__glacier_argument" in
    *';') __glacier_argument="${__glacier_argument%?}\\;" ;;
  esac
  printf -v "$2" '%s' "$__glacier_argument"
}

# Apply format protection and argv protection to the name once each.
prepare_tmux_option_name() {
  local __glacier_prepared_name="${1//#/##}"
  escape_tmux_argument "$__glacier_prepared_name" "$2"
}

# Remove only the single output newline appended by tmux.
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

# Restore the Base64 field to an output variable without losing newlines.
decode_option_field() {
  case "$1" in b64:*) ;; *) return 1 ;; esac
  init_base64_decoder || return 1
  local __glacier_decoded
  __glacier_decoded="$(printf '%s' "${1#b64:}" | decode_base64; __glacier_status=$?; printf '\034'; exit "$__glacier_status")" || return 1
  __glacier_decoded="${__glacier_decoded%$'\034'}"
  printf -v "$2" '%s' "$__glacier_decoded"
}

# Determine the local name using exact output boundaries for the full listing and direct name lookup.
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
