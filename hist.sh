#!/usr/bin/env bash
# hist.sh — fuzzy-pick a command from shell history

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init hist.sh

load_history() {
  local file=${HISTFILE:-}
  local -a lines=()

  if [[ -z $file ]]; then
    if [[ -f $HOME/.zsh_history ]]; then
      file=$HOME/.zsh_history
    else
      file=$HOME/.bash_history
    fi
  fi

  if [[ -r $file ]]; then
    # bash: plain lines; zsh: ": unixtime:duration;command"
    mapfile -t lines < <(
      LC_ALL=C tac "$file" 2>/dev/null \
        | LC_ALL=C sed -E 's/^: [0-9]+:[0-9]+;//' \
        | LC_ALL=C awk 'NF && !seen[$0]++'
    )
  elif [[ -n ${BASH_VERSION:-} ]]; then
    mapfile -t lines < <(
      LC_ALL=C history | LC_ALL=C awk '{$1=""; sub(/^ /,""); if ($0 != "") print}' \
        | LC_ALL=C tac | LC_ALL=C awk '!seen[$0]++'
    )
  else
    die 'no readable history found'
  fi

  ((${#lines[@]} > 0)) || die 'history is empty'
  printf '%s\n' "${lines[@]}"
}

pick_command() {
  local -a cmds=()
  mapfile -t cmds < <(load_history)

  fsh_menu_defaults
  f_prompt='Command: '
  f_height=15
  f_border=1
  f_select "${cmds[@]}"
}

copy_cmd() {
  local cmd=$1
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$cmd" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$cmd" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$cmd" | xsel --clipboard --input
  else
    die 'no clipboard tool (wl-copy, xclip, xsel)'
  fi
  printf '\033[1m%s\033[0m\n' "$cmd"
  sleep 3
}

main() {
  local action cmd

  while true; do
    cmd=$(pick_command) || exit 0

    fsh_menu_defaults
    f_prompt='Action: '
    f_height=6
    action=$(f_select \
      'Run command' \
      'Print command' \
      'Copy to clipboard' \
      'Pick another' \
      'Quit') || exit 0

    case "$action" in
      'Run command')
        printf 'Running: %s\n' "$cmd" >&2
        # shellcheck disable=SC2090
        eval "$cmd"
        ;;
      'Print command')
        printf '%s\n' "$cmd"
        ;;
      'Copy to clipboard')
        copy_cmd "$cmd"
        ;;
      'Pick another')
        continue
        ;;
      'Quit')
        exit 0
        ;;
    esac
  done
}

main "$@"
