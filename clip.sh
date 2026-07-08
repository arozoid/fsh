#!/usr/bin/env bash
# clip.sh — clipboard history picker

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/lib/common.sh"
fsh_init clip.sh

CLIP_FILE="${FSH_CLIP_FILE:-$HOME/.cache/fsh/clipboard.txt}"

_fsh_read_clipboard() {
  if command -v wl-paste >/dev/null 2>&1; then
    wl-paste 2>/dev/null
  elif command -v xclip >/dev/null 2>&1; then
    xclip -o -selection clipboard 2>/dev/null
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output 2>/dev/null
  fi
}

append_clipboard() {
  local current
  current=$(_fsh_read_clipboard) || return 0
  [[ -n $current ]] || return 0
  [[ -f $CLIP_FILE && $(head -1 "$CLIP_FILE") == "$current" ]] && return 0
  mkdir -p "$(dirname "$CLIP_FILE")"
  {
    printf '%s\n' "$current"
    [[ -f $CLIP_FILE ]] && cat "$CLIP_FILE"
  } >"${CLIP_FILE}.tmp" && mv "${CLIP_FILE}.tmp" "$CLIP_FILE"
  local max=${FSH_CLIP_MAX:-50}
  local lines
  lines=$(wc -l <"$CLIP_FILE")
  if ((lines > max)); then
    head -n "$max" "$CLIP_FILE" >"${CLIP_FILE}.tmp" && mv "${CLIP_FILE}.tmp" "$CLIP_FILE"
  fi
}

main() {
  append_clipboard

  [[ -f $CLIP_FILE ]] || die 'clipboard is empty'

  fsh_menu_defaults
  f_prompt='Clipboard: '
  f_height=15
  f_border=1
  choice=$(f_select_file "$CLIP_FILE") || exit 0

  printf '%s' "$choice" | fsh_clipboard
  printf 'Copied: %s\n' "${choice:0:80}" >&2
}

main "$@"
