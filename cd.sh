#!/usr/bin/env bash
# cd.sh — navigate directories and output cd command

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
fsh_init cd.sh

main() {
  local target_dir=$PWD items=() choice parent

  while true; do
    items=("✓ Select this directory")
    parent=$(dirname "$target_dir")
    [[ $parent != "$target_dir" ]] && items+=("..")

    for d in "$target_dir"/*/; do
      [[ -d $d ]] || continue
      items+=("$(basename "$d")")
    done

    fsh_menu_defaults
    f_prompt="$target_dir/: "
    f_height=15
    f_border=1
    choice=$(f_select "${items[@]}") || exit 1

    case $choice in
      '✓ Select this directory')
        printf 'cd %s\n' "$target_dir"
        exit 0
        ;;
      '..')
        target_dir=$parent
        ;;
      *)
        target_dir=$target_dir/$choice
        ;;
    esac
  done
}

main "$@"
