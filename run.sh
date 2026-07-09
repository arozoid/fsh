#!/usr/bin/env bash
# run.sh — launcher for f.sh sample scripts

set -euo pipefail

_fsh_self_dir() {
  local src=${BASH_SOURCE[0]} link
  while [[ -L $src ]]; do
    link=$(readlink "$src")
    if [[ $link == /* ]]; then
      src=$link
    else
      src=$(cd "$(dirname "$src")" && pwd)/$link
    fi
  done
  cd "$(dirname "$src")" && pwd
}

DIR=$(_fsh_self_dir)
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init run.sh

load_scripts() {
  fsh_discover_scripts || die 'no fsh scripts found in search paths'
}

run_script() {
  local entry=$1 path rc
  path=$(fsh_script_path_for "$entry") || die "unknown script: $entry"
  printf '\n── %s ──\n' "$entry" >&2
  set +e
  bash "$path"
  rc=$?
  set -e
  return "$rc"
}

main() {
  local choice

  while true; do
    load_scripts
    fsh_menu_defaults
    f_prompt='Run: '
    f_height=15
    f_search_delay=100
    f_border=1
    choice=$(f_select "${FSH_SCRIPT_LABELS[@]}") || exit 0
    run_script "$choice" || true
    printf '\nPress Enter to return to menu…' >&2
    read -r _ </dev/tty
  done
}

# Run when executed directly or via /bin/fsh launcher (argv0 may be "fsh").
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  main "$@"
fi
