#!/usr/bin/env bash
# wifi.sh — Wi-Fi manager (nmcli or wpa_cli / wpa_supplicant)

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init wifi.sh

WIFI_BACKEND=''
IFACE=''

have_nmcli() {
  command -v nmcli >/dev/null 2>&1
}

have_wpa() {
  command -v wpa_cli >/dev/null 2>&1 && command -v wpa_supplicant >/dev/null 2>&1
}

available_backends() {
  local -a backends=()
  have_nmcli && backends+=(nmcli)
  have_wpa && backends+=(wpa)
  ((${#backends[@]} > 0)) || die 'need nmcli or wpa_cli+wpa_supplicant'
  printf '%s\n' "${backends[@]}"
}

pick_backend() {
  local -a backends=()
  mapfile -t backends < <(available_backends)
  if ((${#backends[@]} == 1)); then
    printf '%s' "${backends[0]}"
    return 0
  fi
  fsh_menu_defaults
  f_prompt='Wi-Fi backend: '
  f_height=6
  f_select "${backends[@]}"
}

init_backend() {
  if [[ -n ${WIFI_BACKEND:-} ]]; then
    case "$WIFI_BACKEND" in
      nmcli)
        have_nmcli || die 'nmcli not found'
        ;;
      wpa)
        have_wpa || die 'wpa_cli / wpa_supplicant not found'
        ;;
      *)
        die "unknown WIFI_BACKEND: $WIFI_BACKEND (use nmcli or wpa)"
        ;;
    esac
    return 0
  fi

  local -a backends=()
  mapfile -t backends < <(available_backends)
  if ((${#backends[@]} == 1)); then
    WIFI_BACKEND=${backends[0]}
    return 0
  fi

  if have_nmcli && nmcli general status >/dev/null 2>&1; then
    WIFI_BACKEND=nmcli
  else
    WIFI_BACKEND=wpa
  fi
}

# --- nmcli backend ---

nm_detect_iface() {
  if [[ -n ${WIFI_IFACE:-} ]]; then
    printf '%s' "$WIFI_IFACE"
    return 0
  fi
  nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
    | awk -F: '$2=="wifi"{print $1; exit}'
}

nm_scan_networks() {
  nmcli -t -f SSID,IN-USE device wifi list ifname "$IFACE" 2>/dev/null \
    | awk -F: '$1 != "" && $1 != "--" { print $1 }' \
    | sort -fu
}

nm_connect_network() {
  local ssid=$1 pass=$2
  if [[ -n $pass ]]; then
    nmcli device wifi connect "$ssid" ifname "$IFACE" password "$pass"
  else
    nmcli device wifi connect "$ssid" ifname "$IFACE"
  fi
}

nm_disconnect() {
  nmcli device disconnect "$IFACE" >/dev/null
}

nm_show_status() {
  printf 'Backend: nmcli\nInterface: %s\n\n' "$IFACE"
  nmcli device show "$IFACE"
  printf '\n'
  nmcli connection show --active 2>/dev/null || true
}

# --- wpa_cli backend ---

wpa_detect_iface() {
  if [[ -n ${WIFI_IFACE:-} ]]; then
    printf '%s' "$WIFI_IFACE"
    return 0
  fi

  local iface
  if command -v ip >/dev/null 2>&1; then
    iface=$(ip -o link show type wlan 2>/dev/null | awk -F': ' '{print $2; exit}')
    [[ -n $iface ]] && { printf '%s' "$iface"; return 0; }
  fi
  if command -v iw >/dev/null 2>&1; then
    iface=$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')
    [[ -n $iface ]] && { printf '%s' "$iface"; return 0; }
  fi
  return 1
}

wpa() { wpa_cli -i "$IFACE" "$@"; }

wpa_ensure_supplicant() {
  if wpa ping 2>/dev/null | grep -q '^PONG$'; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start "wpa_supplicant@${IFACE}.service" 2>/dev/null \
      || systemctl start wpa_supplicant@"$IFACE" 2>/dev/null \
      || systemctl start wpa_supplicant.service 2>/dev/null \
      || true
    sleep 0.5
    wpa ping 2>/dev/null | grep -q '^PONG$' && return 0
  fi
  die "wpa_supplicant is not running on $IFACE (try: sudo systemctl start wpa_supplicant@${IFACE})"
}

wpa_scan_networks() {
  wpa_ensure_supplicant
  wpa scan >/dev/null 2>&1 || true
  sleep 2
  wpa scan_results | awk -F'\t' 'NR > 1 && NF >= 5 && $5 != "" { print $5 }' | sort -fu
}

wpa_connect_network() {
  local ssid=$1 pass=$2 nid state
  wpa_ensure_supplicant
  nid=$(wpa add_network | awk '{print $NF}')
  [[ $nid =~ ^[0-9]+$ ]] || die 'wpa_cli add_network failed'
  wpa set_network "$nid" ssid "\"$ssid\"" >/dev/null
  if [[ -n $pass ]]; then
    wpa set_network "$nid" psk "\"$pass\"" >/dev/null
    wpa set_network "$nid" key_mgmt WPA-PSK >/dev/null
  else
    wpa set_network "$nid" key_mgmt NONE >/dev/null
  fi
  wpa enable_network "$nid" >/dev/null
  wpa select_network "$nid" >/dev/null
  wpa save_config >/dev/null 2>&1 || true
  wpa reconnect >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    state=$(wpa status | awk -F= '/^wpa_state=/{print $2; exit}')
    [[ $state == 'COMPLETED' ]] && break
    sleep 1
  done
  wpa status | awk -F= '/^wpa_state=/{print $2; exit}'
}

wpa_disconnect() {
  wpa_ensure_supplicant
  wpa disconnect >/dev/null
}

wpa_show_status() {
  wpa_ensure_supplicant
  printf 'Backend: wpa_cli\nInterface: %s\n\n' "$IFACE"
  wpa status
  printf '\n'
  wpa list_networks 2>/dev/null || true
}

# --- shared ---

detect_iface() {
  local iface
  case "$WIFI_BACKEND" in
    nmcli) iface=$(nm_detect_iface) ;;
    wpa)   iface=$(wpa_detect_iface) ;;
    *)     die "unknown backend: $WIFI_BACKEND" ;;
  esac
  [[ -n $iface ]] || die 'no wireless interface found (set WIFI_IFACE)'
  IFACE=$iface
}

scan_networks() {
  case "$WIFI_BACKEND" in
    nmcli) nm_scan_networks ;;
    wpa)   wpa_scan_networks ;;
  esac
}

connect_network() {
  local ssid=$1 pass
  printf 'Password for %s (empty for open): ' "$ssid" >&2
  read -rs pass </dev/tty
  printf '\n' >&2
  printf 'Connecting to %s…\n' "$ssid" >&2
  case "$WIFI_BACKEND" in
    nmcli) nm_connect_network "$ssid" "$pass" ;;
    wpa)   wpa_connect_network "$ssid" "$pass" ;;
  esac
}

disconnect_wifi() {
  case "$WIFI_BACKEND" in
    nmcli) nm_disconnect ;;
    wpa)   wpa_disconnect ;;
  esac
  printf 'Disconnected.\n' >&2
}

show_status() {
  case "$WIFI_BACKEND" in
    nmcli) nm_show_status ;;
    wpa)   wpa_show_status ;;
  esac
}

pick_action() {
  local -a actions backends=()
  mapfile -t backends < <(available_backends)

  actions=(
    'Connect to network'
    'Disconnect'
    'Show status'
  )
  ((${#backends[@]} > 1)) && actions+=("Switch backend ($WIFI_BACKEND)")
  actions+=('Quit')

  fsh_menu_defaults
  f_prompt="Wi-Fi [$WIFI_BACKEND]: "
  f_height=10
  f_select "${actions[@]}"
}

pick_network() {
  local -a networks=('↻ Refresh scan')
  local choice

  mapfile -t -O 1 networks < <(scan_networks)
  ((${#networks[@]} > 1)) || die 'no networks found'

  fsh_menu_defaults
  f_prompt="SSID ($IFACE): "
  f_height=12
  f_border=1
  choice=$(f_select "${networks[@]}") || return 1

  if [[ $choice == '↻ Refresh scan' ]]; then
    printf 'Scanning…\n' >&2
    pick_network
    return $?
  fi

  printf '%s' "$choice"
}

main() {
  local action ssid

  init_backend
  detect_iface

  while true; do
    action=$(pick_action) || exit 0

    case "$action" in
      'Connect to network')
        ssid=$(pick_network) || continue
        connect_network "$ssid"
        ;;
      'Disconnect')
        disconnect_wifi
        ;;
      'Show status')
        show_status | "${PAGER:-less -R}"
        ;;
      Switch\ backend*)
        WIFI_BACKEND=$(pick_backend) || continue
        detect_iface
        ;;
      'Quit')
        exit 0
        ;;
    esac
  done
}

main "$@"
