#!/usr/bin/env bash
# power.sh — simple session / power menu

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init power.sh

pick_action() {
  local actions=(
    'Lock screen'
    'Suspend'
    'Log out'
    'Reboot'
    'Shutdown'
    'Cancel'
  )
  fsh_menu_defaults
  f_prompt='Power: '
  f_height=8
  f_border=1
  f_select "${actions[@]}"
}

confirm() {
  local msg=$1
  fsh_menu_defaults
  f_prompt="$msg "
  f_height=4
  f_select 'Yes' 'No'
}

lock_screen() {
  if command -v loginctl >/dev/null 2>&1; then
    loginctl lock-session
  elif command -v swaylock >/dev/null 2>&1; then
    swaylock
  elif command -v hyprlock >/dev/null 2>&1; then
    hyprlock
  else
    die 'no lock command found (loginctl, swaylock, hyprlock)'
  fi
}

suspend_system() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl suspend
  elif command -v loginctl >/dev/null 2>&1; then
    loginctl suspend
  else
    die 'cannot suspend (need systemctl or loginctl)'
  fi
}

logout_session() {
  if command -v loginctl >/dev/null 2>&1; then
    loginctl terminate-user "$USER"
  elif command -v pkill >/dev/null 2>&1; then
    pkill -KILL -u "$USER"
  else
    die 'cannot log out'
  fi
}

reboot_system() {
  command -v systemctl >/dev/null 2>&1 || die 'systemctl required'
  systemctl reboot
}

shutdown_system() {
  command -v systemctl >/dev/null 2>&1 || die 'systemctl required'
  systemctl poweroff
}

main() {
  local action answer

  action=$(pick_action) || exit 0

  case "$action" in
    'Lock screen') lock_screen ;;
    'Suspend')
      [[ $(confirm 'Suspend?') == 'Yes' ]] && suspend_system
      ;;
    'Log out')
      [[ $(confirm 'Log out?') == 'Yes' ]] && logout_session
      ;;
    'Reboot')
      [[ $(confirm 'Reboot?') == 'Yes' ]] && reboot_system
      ;;
    'Shutdown')
      [[ $(confirm 'Shutdown?') == 'Yes' ]] && shutdown_system
      ;;
    'Cancel') exit 0 ;;
  esac
}

main "$@"
