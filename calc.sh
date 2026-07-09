#!/usr/bin/env bash
# calc.sh — interactive calculator with session history

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
fsh_init calc.sh

_calc_history=()

_calc_evaluate() {
  local expr=$1 result
  expr=${expr//×/*}
  expr=${expr//x/*}
  expr=${expr//,/.}

  result=$(echo "scale=10; $expr" | bc -l 2>/dev/null | sed '/^error/d;s/^\./0./' | sed -E 's/(\.[0-9]*[1-9])0+$/\1/;s/\.0+$//')
  if [[ -n $result ]]; then
    printf '%s' "$result"
    return 0
  fi

  if command -v qalc >/dev/null 2>&1; then
    result=$(printf '%s' "$expr" | qalc 2>/dev/null | sed '1d;/^$/d;$!d' | sed 's/^[[:space:]]*≈ //;s/^[[:space:]]*= //')
    [[ -n $result ]] && { printf '%s' "$result"; return 0; }
  fi

  return 1
}

_calc_provider() {
  local query=$1 entry

  if [[ -n $query ]]; then
    local result
    result=$(_calc_evaluate "$query" 2>/dev/null) || result='error'
    if [[ $result == 'error' ]]; then
      printf '\033[1m%s = ???\n' "$query"
    else
      printf '\033[1m%s = %s\n' "$query" "$result"
    fi
  fi

  for entry in "${_calc_history[@]}"; do
    printf '%s\n' "$entry"
  done
}

main() {
  local choice expr result

  while true; do
    fsh_menu_defaults
    f_no_search=1
    f_hints=0
    f_color_selected=$'\033[33m'
    f_prompt='Calculate: '
    f_height=12
    f_border=1
    choice=$(f_select_dynamic _calc_provider) || exit 0

    if [[ $choice == $'\033[1m'* ]]; then
      expr=${choice#$'\033[1m'}
      _calc_history+=("$expr")
      result=${expr#* = }
    else
      result=${choice#* = }
      result=${result#* ≈ }
    fi
    printf '%s' "$result" | fsh_clipboard
    printf '\033[1m%s\033[0m\n' "$result"
    sleep 3
  done
}

main "$@"
