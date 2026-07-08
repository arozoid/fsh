#!/usr/bin/env bash
# bt.sh — minimal Bluetooth device picker via bluetoothctl

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init bt.sh

command -v bluetoothctl >/dev/null 2>&1 || die 'bluetoothctl is required'

bt() { bluetoothctl "$@"; }

list_devices() {
  bt devices | sed 's/^Device //' | sort -u
}

paired_devices() {
  bt paired-devices | sed 's/^Device /[paired] /'
}

scan_devices() {
  printf 'Scanning (5s)…\n' >&2
  bt --timeout 5 scan on >/dev/null 2>&1 || true
  sleep 5
  bt --timeout 2 scan off >/dev/null 2>&1 || true
}

pick_action() {
  local actions=(
    'Connect to device'
    'Scan and connect'
    'Show paired devices'
    'Disconnect'
    'Power on adapter'
    'Quit'
  )
  fsh_menu_defaults
  f_prompt='Bluetooth: '
  f_height=10
  f_select "${actions[@]}"
}

device_mac() {
  printf '%s' "$1" | awk '{print $1}'
}

connect_device() {
  local entry=$1 mac name
  mac=$(device_mac "$entry")
  name=${entry#"$mac "}

  bt power on >/dev/null 2>&1 || true
  bt trust "$mac" >/dev/null 2>&1 || true
  bt pair "$mac" >/dev/null 2>&1 || true
  bt connect "$mac"

  printf 'Connected to %s (%s)\n' "$name" "$mac" >&2
}

connect_flow() {
  local do_scan=$1
  local tmpfile choice

  if ((do_scan)); then
    scan_devices
  fi

  tmpfile=$(mktemp) || return 1
  list_devices >"$tmpfile"
  (($(wc -l <"$tmpfile") > 0)) || { rm -f "$tmpfile"; die 'no devices found — try Scan and connect'; }

  fsh_menu_defaults
  f_prompt='Device: '
  f_height=12
  f_border=1
  choice=$(f_select_file "$tmpfile") || { rm -f "$tmpfile"; return 1; }
  rm -f "$tmpfile"

  connect_device "$choice"
}

main() {
  local action

  while true; do
    action=$(pick_action) || exit 0

    case "$action" in
      'Connect to device')
        connect_flow 0 || true
        ;;
      'Scan and connect')
        connect_flow 1 || true
        ;;
      'Show paired devices')
        paired_devices | "${PAGER:-less -R}"
        ;;
      'Disconnect')
        bt disconnect 2>/dev/null || true
        printf 'Disconnected.\n' >&2
        ;;
      'Power on adapter')
        bt power on
        ;;
      'Quit')
        exit 0
        ;;
    esac
  done
}

main "$@"
