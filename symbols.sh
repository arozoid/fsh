#!/usr/bin/env bash
# symbols.sh — copy emojis and unicode symbols

set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/lib/common.sh"
fsh_init unicode.sh

SYMBOLS_FILE="$DIR/symbols.txt"

[[ -f $SYMBOLS_FILE ]] || die "symbols database not found: $SYMBOLS_FILE"

f_min_query_length=2
f_prompt='Unicode: '
f_fuzzy=0
choice=$(f_select_file "$SYMBOLS_FILE") || exit 0

symbol=${choice%% *}

printf '%s' "$symbol" | fsh_clipboard
printf '\033[1m%s\033[0m\n' "$symbol"
sleep 3
