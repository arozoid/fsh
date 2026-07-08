#!/usr/bin/env bash
# s.sh — pick an SSH host from config / hosts files

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init s.sh

command -v ssh >/dev/null 2>&1 || die 'ssh is required'

SSH_HOST_FILES=(
  "${SSH_HOSTS_FILE:-}"
  "$HOME/.ssh/hosts"
  "$HOME/.ssh/config"
  /etc/ssh/ssh_config
  "$HOME/.ssh/known_hosts"
)

collect_hosts() {
  local file
  local -A seen=()

  for file in "${SSH_HOST_FILES[@]}"; do
    [[ -n $file && -r $file ]] || continue
    while IFS= read -r host; do
      [[ -n $host ]] || continue
      [[ -n ${seen[$host]:-} ]] && continue
      seen[$host]=1
      printf '%s\n' "$host"
    done < <(awk '
      /^[[:space:]]*#/ { next }
      /^[Hh][Oo][Ss][Tt][[:space:]]+/ {
        host = $2
        if (host !~ /[*?]/) print host
        next
      }
      /^[^#[:space:]][^[:space:]]+/ {
        if (FILENAME ~ /hosts$/) print $1
        if (FILENAME ~ /known_hosts$/) {
          host = $1
          gsub(/^\[|\]:[0-9]+$/, "", host)
          gsub(/,.*$/, "", host)
          if (host !~ /^[0-9.]+$/ && host !~ /^[0-9a-fA-F:]+$/ && host !~ /[*?]/) print host
        }
      }
    ' "$file" 2>/dev/null)
  done | sort -fu
}

host_label() {
  local host=$1 user target
  if [[ $host == *@* ]]; then
    printf '%s' "$host"
    return 0
  fi
  user=$(awk -v h="$host" '
    $1 ~ /^[Hh][Oo][Ss][Tt]$/ && $2 == h { inhost=1; next }
    inhost && $1 ~ /^[Hh][Oo][Ss][Tt]$/ { exit }
    inhost && $1 ~ /^[Uu][Ss][Ee][Rr]$/ { print $2; exit }
  ' "$HOME/.ssh/config" 2>/dev/null)
  if [[ -n $user ]]; then
    printf '%s@%s' "$user" "$host"
  else
    printf '%s' "$host"
  fi
}

pick_host() {
  local tmpfile
  tmpfile=$(mktemp) || return 1
  collect_hosts >"$tmpfile"
  [[ -s $tmpfile ]] || { rm -f "$tmpfile"; die 'no SSH hosts found (~/.ssh/config, ~/.ssh/hosts, ~/.ssh/known_hosts)'; }

  fsh_menu_defaults
  f_prompt='SSH host: '
  f_height=15
  f_border=1
  f_select_file "$tmpfile"
  local rc=$?
  rm -f "$tmpfile"
  return "$rc"
}

connect_host() {
  local host=$1 target action extra

  target=$(host_label "$host")

  fsh_menu_defaults
  f_prompt="$target: "
  f_height=6
  action=$(f_select \
    'Connect' \
    'Copy ssh command' \
    'Connect with extra args' \
    'Pick another' \
    'Quit') || return 1

  case "$action" in
    Connect)
      printf 'Connecting to %s…\n' "$target" >&2
      exec ssh "$target"
      ;;
    'Copy ssh command')
      local cmd="ssh $target"
      if command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$cmd" | wl-copy
      elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$cmd" | xclip -selection clipboard
      elif command -v xsel >/dev/null 2>&1; then
        printf '%s' "$cmd" | xsel --clipboard --input
      else
        die 'no clipboard tool (wl-copy, xclip, xsel)'
      fi
      printf 'Copied: %s\n' "$cmd" >&2
      ;;
    'Connect with extra args')
      printf 'Extra ssh args: ' >&2
      read -r extra </dev/tty
      # shellcheck disable=SC2086
      exec ssh $extra "$target"
      ;;
    'Pick another')
      return 0
      ;;
    Quit)
      exit 0
      ;;
  esac
}

main() {
  local host
  while true; do
    host=$(pick_host) || exit 0
    connect_host "$host"
  done
}

main "$@"
