#!/usr/bin/env bash
# p.sh — search processes and run actions

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init p.sh

command -v ps >/dev/null 2>&1 || die 'ps is required'

P_MAX=${P_MAX:-400}

list_processes() {
  if ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu >/dev/null 2>&1; then
    ps -eo pid=,user=,pcpu=,pmem=,args= --sort=-pcpu \
      | awk -v max="$P_MAX" '{
          pid=$1; user=$2; cpu=$3+0; mem=$4+0
          cmd=$0; sub(/^[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+ +/, "", cmd)
          printf "%6s %-8s %5.1f %5.1f %s\n", pid, user, cpu, mem, cmd
        }' | head -n "$P_MAX"
    return 0
  fi
  ps aux --sort=-%cpu 2>/dev/null \
    | awk -v max="$P_MAX" 'NR > 1 && NR <= max + 1 {
        printf "%6s %-8s %5.1f %5.1f %s\n", $2, $1, $3+0, $4+0, substr($0, index($0,$11))
      }'
}

proc_pid() { awk '{print $1}' <<<"$1"; }

proc_details() {
  local pid=$1
  ps -p "$pid" -o pid=,user=,pcpu=,pmem=,etime=,args= 2>/dev/null \
    || die "process $pid not found"
}

confirm() {
  local msg=$1
  fsh_menu_defaults
  f_prompt="$msg "
  f_height=4
  f_select 'yes' 'no'
}

copy_text() {
  local text=$1
  if command -v wl-copy >/dev/null 2>&1; then
    printf '%s' "$text" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    printf '%s' "$text" | xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    printf '%s' "$text" | xsel --clipboard --input
  else
    die 'no clipboard tool (wl-copy, xclip, xsel)'
  fi
  printf 'copied: %s\n' "$text" >&2
}

pick_process() {
  _f_items=()
  mapfile -t _f_items < <(list_processes)
  ((${#_f_items[@]} > 0)) || die 'no processes found'

  fsh_menu_defaults
  f_prompt='process: '
  f_height=15
  f_border=1
  f_fuzzy=0
  f_select
}

do_action() {
  local entry=$1 pid action answer
  pid=$(proc_pid "$entry")

  fsh_menu_defaults
  f_prompt="pid $pid: "
  f_height=10
  action=$(f_select \
    'show details' \
    'send sigterm' \
    'send sigkill' \
    'copy pid' \
    'pick another' \
    'quit') || return 1

  case "$action" in
    'show details')
      printf '\n%s\n' "$(proc_details "$pid")" >&2
      ;;
    'send sigterm')
      answer=$(confirm "kill $pid?") || return 0
      [[ $answer == yes ]] || return 0
      kill "$pid" 2>/dev/null || die "could not kill $pid"
      printf 'sent sigterm to %s\n' "$pid" >&2
      ;;
    'send sigkill')
      answer=$(confirm "kill -9 $pid?") || return 0
      [[ $answer == yes ]] || return 0
      kill -9 "$pid" 2>/dev/null || die "could not kill $pid"
      printf 'sent sigkill to %s\n' "$pid" >&2
      ;;
    'copy pid')
      copy_text "$pid"
      ;;
    'pick another')
      return 2
      ;;
    quit)
      exit 0
      ;;
  esac
}

main() {
  local entry rc=0
  while true; do
    entry=$(pick_process) || exit 0
    do_action "$entry" || rc=$?
    [[ $rc -eq 2 ]] && continue
  done
}

main "$@"
