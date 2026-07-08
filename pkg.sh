#!/usr/bin/env bash
# pkg.sh — interactive package management (apk, apt, dnf, pacman)

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init pkg.sh

PKG_MGR=''
PKG_SUDO=''

pick_manager() {
  local -a mgrs=()
  if [[ -n ${PKG_MANAGER:-} ]]; then
    PKG_MGR=$PKG_MANAGER
    return 0
  fi
  command -v apk >/dev/null 2>&1 && mgrs+=(apk)
  command -v apt >/dev/null 2>&1 && mgrs+=(apt)
  command -v dnf >/dev/null 2>&1 && mgrs+=(dnf)
  command -v pacman >/dev/null 2>&1 && mgrs+=(pacman)
  ((${#mgrs[@]} > 0)) || die 'no package managers found'

  if ((${#mgrs[@]} == 1)); then
    PKG_MGR=${mgrs[0]}
    return 0
  fi

  fsh_menu_defaults
  f_prompt='Package manager: '
  f_height=6
  PKG_MGR=$(f_select "${mgrs[@]}") || die 'cancelled'
}

need_sudo() {
  [[ $EUID -eq 0 ]] && return 0
  command -v sudo >/dev/null 2>&1 || die 'root or sudo required'
  PKG_SUDO=sudo
}

pick_action() {
  local actions=(
    'Search and install'
    'Remove package'
    'Upgrade system'
    'List installed'
    'Quit'
  )
  fsh_menu_defaults
  f_prompt="[$PKG_MGR] "
  f_height=8
  f_select "${actions[@]}"
}

pkg_search() {
  local query=$1
  case "$PKG_MGR" in
    apk)    apk search -v "$query" 2>/dev/null | awk '{print $1}' | sort -u ;;
    apt)    apt-cache search "$query" 2>/dev/null | awk '{print $1}' ;;
    dnf)    dnf -q list --available "*${query}*" 2>/dev/null | awk 'NR>1 && $1!="Available" {print $1}' ;;
    pacman) pacman -Ss "$query" 2>/dev/null \
              | awk '!/^[[:space:]]/ && NF {gsub(/\033\[[0-9;]*m/,""); print $1}' | sort -u ;;
  esac
}

pkg_installed() {
  case "$PKG_MGR" in
    apk)    apk info -q 2>/dev/null | sort ;;
    apt)    dpkg-query -W -f='${Package}\n' 2>/dev/null | sort ;;
    dnf)    dnf -q list --installed 2>/dev/null | awk 'NR>1 && $1!="Installed" {print $1}' | sort -u ;;
    pacman) pacman -Qq 2>/dev/null | sort ;;
  esac
}

_f_pkg_installed_provider() {
  pkg_installed
}

pick_from_list() {
  local prompt=$1
  shift
  local -a items=()
  mapfile -t items < <("$@")
  ((${#items[@]} > 0)) || die 'no packages found'

  fsh_menu_defaults
  f_prompt="$prompt "
  f_height=15
  f_border=1
  f_select "${items[@]}"
}

prompt_query() {
  local q
  printf 'Search query: ' >&2
  read -r q </dev/tty
  [[ -n $q ]] || die 'empty query'
  printf '%s' "$q"
}

pkg_install() {
  local pkg=$1
  need_sudo
  case "$PKG_MGR" in
    apk)    $PKG_SUDO apk add "$pkg" ;;
    apt)    $PKG_SUDO apt install -y "$pkg" ;;
    dnf)    $PKG_SUDO dnf install -y "$pkg" ;;
    pacman) $PKG_SUDO pacman -S --noconfirm "$pkg" ;;
  esac
}

pkg_remove() {
  local pkg=$1
  need_sudo
  case "$PKG_MGR" in
    apk)    $PKG_SUDO apk del "$pkg" ;;
    apt)    $PKG_SUDO apt remove -y "$pkg" ;;
    dnf)    $PKG_SUDO dnf remove -y "$pkg" ;;
    pacman) $PKG_SUDO pacman -R --noconfirm "$pkg" ;;
  esac
}

pkg_upgrade() {
  need_sudo
  case "$PKG_MGR" in
    apk)    $PKG_SUDO apk upgrade ;;
    apt)    $PKG_SUDO apt update && $PKG_SUDO apt upgrade -y ;;
    dnf)    $PKG_SUDO dnf upgrade -y ;;
    pacman) $PKG_SUDO pacman -Syu --noconfirm ;;
  esac
}

search_and_install() {
  local query pkg
  query=$(prompt_query)
  pkg=$(pick_from_list 'Install:' pkg_search "$query") || return 0
  pkg_install "$pkg"
}

main() {
  local action pkg

  pick_manager
  printf 'Using %s\n' "$PKG_MGR" >&2

  while true; do
    action=$(pick_action) || exit 0

    case "$action" in
      'Search and install')
        search_and_install
        ;;
      'Remove package')
        fsh_menu_defaults
        f_min_query_length=2
        f_prompt='Remove: '
        f_height=15
        f_border=1
        pkg=$(f_select_dynamic _f_pkg_installed_provider) || continue
        pkg_remove "$pkg"
        ;;
      'Upgrade system')
        pkg_upgrade
        ;;
      'List installed')
        fsh_menu_defaults
        f_prompt='Installed: '
        f_height=15
        f_border=1
        f_select_dynamic _f_pkg_installed_provider >/dev/null || true
        ;;
      'Quit')
        exit 0
        ;;
    esac
  done
}

main "$@"
