#!/usr/bin/env bash
# ss.sh — Wayland screenshots via grim + slurp

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init ss.sh

command -v grim >/dev/null 2>&1 || die 'grim is required'
command -v slurp >/dev/null 2>&1 || die 'slurp is required'

OUT_DIR="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
mkdir -p "$OUT_DIR"

timestamp() { date +%Y%m%d-%H%M%S; }

pick_mode() {
  local modes=(
    'Full screen'
    'Select region'
    'Select output (monitor)'
    'Active window'
  )
  fsh_menu_defaults
  f_prompt='Capture: '
  f_height=8
  f_select "${modes[@]}"
}

pick_delay() {
  local delays=(
    'No delay'
    '3 seconds'
    '5 seconds'
    '10 seconds'
  )
  fsh_menu_defaults
  f_prompt='Delay: '
  f_height=6
  f_select "${delays[@]}"
}

delay_seconds() {
  case "$1" in
    'No delay') echo 0 ;;
    '3 seconds') echo 3 ;;
    '5 seconds') echo 5 ;;
    '10 seconds') echo 10 ;;
    *) echo 0 ;;
  esac
}

countdown() {
  local secs=$1 i
  ((secs == 0)) && return 0
  for ((i = secs; i > 0; i--)); do
    printf 'Capturing in %ds…\r' "$i" >&2
    sleep 1
  done
  printf '%s\r' "$(printf ' %.0s' {1..30})" >&2
}

window_geometry() {
  if command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    hyprctl activewindow -j | jq -r '
      select(.address != "0x0") |
      "\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"'
    return 0
  fi
  if command -v swaymsg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    swaymsg -t get_tree | jq -r '
      .. | select(.focused? == true and .rect?) |
      "\(.rect.x),\(.rect.y) \(.rect.width)x\(.rect.height)"' | head -1
    return 0
  fi
  return 1
}

capture() {
  local mode=$1 delay=$2
  local outfile="$OUT_DIR/screenshot-$(timestamp).png"
  local secs geom output

  secs=$(delay_seconds "$delay")
  countdown "$secs"

  case "$mode" in
    'Full screen')
      grim "$outfile"
      ;;
    'Select region')
      geom=$(slurp) || die 'region selection cancelled'
      grim -g "$geom" "$outfile"
      ;;
    'Select output (monitor)')
      output=$(slurp -o) || die 'output selection cancelled'
      grim -o "$output" "$outfile"
      ;;
    'Active window')
      if geom=$(window_geometry) && [[ -n $geom ]]; then
        grim -g "$geom" "$outfile"
      else
        die 'active window unavailable (need Hyprland/Sway + jq)'
      fi
      ;;
    *)
      die "unknown mode: $mode"
      ;;
  esac

  printf '%s\n' "$outfile"
  if command -v wl-copy >/dev/null 2>&1; then
    wl-copy <"$outfile"
    printf 'Copied to clipboard.\n' >&2
  fi
}

main() {
  local mode delay path

  while true; do
    mode=$(pick_mode) || exit 0
    delay=$(pick_delay) || continue
    path=$(capture "$mode" "$delay")
    printf 'Saved %s\n' "$path"
  done
}

main "$@"
