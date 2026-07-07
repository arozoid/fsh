#!/usr/bin/env bash
# symbols.sh — copy emojis and unicode symbols

set -euo pipefail

DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$DIR/lib/common.sh"
fsh_init unicode.sh

SYMBOLS_FILE="$DIR/symbols.txt"

[[ -f $SYMBOLS_FILE ]] || die "symbols database not found: $SYMBOLS_FILE"

mapfile -t symbols <"$SYMBOLS_FILE"

f_prompt='Unicode: '
choice=$(f_select "${symbols[@]}") || exit 0

symbol=${choice%% *}

printf '%s' "$symbol" | fsh_clipboard
echo "$symbol"
