#!/usr/bin/env bash
# manage_f.sh — install / uninstall fsh (local ~/fsh or system /fsh)

set -euo pipefail

_fsh_self_dir() {
  local src=${BASH_SOURCE[0]} link
  while [[ -L $src ]]; do
    link=$(readlink "$src")
    if [[ $link == /* ]]; then
      src=$link
    else
      src=$(cd "$(dirname "$src")" && pwd)/$link
    fi
  done
  cd "$(dirname "$src")" && pwd
}

DIR=$(_fsh_self_dir)
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init manage_f.sh

FSH_LOCAL_ROOT=$HOME/fsh
FSH_GLOBAL_ROOT=/fsh
FSH_LOCAL_BIN=$HOME/bin/fsh
FSH_GLOBAL_BIN=/bin/fsh

install_bin_launcher() {
  local fsh_root=$1 bin_path=$2 tmp
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
#!/usr/bin/env bash
exec "$fsh_root/run.sh" "\$@"
EOF
  chmod 755 "$tmp"

  if [[ $bin_path == /bin/* && $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die 'sudo required to install into /bin'
    sudo install -m 755 "$tmp" "$bin_path"
  else
    mkdir -p "$(dirname "$bin_path")"
    install -m 755 "$tmp" "$bin_path"
  fi
  rm -f "$tmp"
  printf 'Launcher: %s → %s/run.sh\n' "$bin_path" "$fsh_root" >&2
}

install_shell_alias() {
  local rc alias_line="alias fsh='$FSH_LOCAL_ROOT/run.sh'"
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f $rc ]] || continue
    grep -qF "$fsh_alias_marker" "$rc" 2>/dev/null && continue
    {
      echo ''
      echo "$fsh_alias_marker"
      echo "$alias_line"
    } >>"$rc"
    printf 'Added fsh alias to %s\n' "$rc" >&2
  done
}

remove_shell_alias() {
  local rc tmp
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f $rc ]] || continue
    grep -qF "$fsh_alias_marker" "$rc" || continue
    tmp=$(mktemp)
    awk -v mark="$fsh_alias_marker" '
      $0 == mark { skip=2; next }
      skip > 0 { skip--; next }
      { print }
    ' "$rc" >"$tmp"
    mv "$tmp" "$rc"
    printf 'Removed fsh alias from %s\n' "$rc" >&2
  done
}

remove_path() {
  local path=$1
  if [[ $path == /fsh || $path == /bin/fsh ]]; then
    command -v sudo >/dev/null 2>&1 || die 'sudo required for system uninstall'
    sudo rm -rf "$path"
  elif [[ $path == /fsh/* ]]; then
    command -v sudo >/dev/null 2>&1 || die 'sudo required for system uninstall'
    sudo rm -f "$path"
  else
    rm -rf "$path"
  fi
}

install_local() {
  local dest=$FSH_LOCAL_ROOT
  mkdir -p "$dest/lib"
  cp -a "$DIR"/*.sh "$dest/"
  cp -a "$DIR"/lib/* "$dest/lib/"
  rm -f "$dest/install_f.sh"
  chmod +x "$dest"/*.sh "$dest"/lib/*.sh
  install_bin_launcher "$dest" "$FSH_LOCAL_BIN"
  install_shell_alias
  printf 'Installed locally to %s\n' "$dest" >&2
  printf 'Use: fsh   (alias) or %s   (if ~/bin is in PATH)\n' "$FSH_LOCAL_BIN" >&2
}

install_global() {
  _install_global_files() {
    mkdir -p /fsh/lib
    cp -a "$DIR"/*.sh /fsh/
    cp -a "$DIR"/lib/* /fsh/lib/
    rm -f /fsh/install_f.sh
    chmod +x /fsh/*.sh /fsh/lib/*.sh
    install_bin_launcher /fsh /bin/fsh
  }
  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die 'sudo required to install to /fsh'
    printf 'Installing to /fsh (sudo)…\n' >&2
    sudo mkdir -p /fsh/lib
    sudo cp -a "$DIR"/*.sh /fsh/
    sudo cp -a "$DIR"/lib/* /fsh/lib/
    sudo rm -f /fsh/install_f.sh
    sudo chmod +x /fsh/*.sh /fsh/lib/*.sh
    install_bin_launcher /fsh /bin/fsh
  else
    _install_global_files
  fi
  printf 'Installed globally to /fsh (command: fsh)\n' >&2
}

uninstall_local() {
  fsh_has_local_install || die 'no local install at ~/fsh'
  remove_path "$FSH_LOCAL_ROOT"
  [[ -f $FSH_LOCAL_BIN || -L $FSH_LOCAL_BIN ]] && remove_path "$FSH_LOCAL_BIN"
  remove_shell_alias
  printf 'Uninstalled local fsh\n' >&2
}

uninstall_global() {
  fsh_has_global_install || die 'no global install at /fsh'
  remove_path "$FSH_GLOBAL_ROOT"
  [[ -f $FSH_GLOBAL_BIN || -L $FSH_GLOBAL_BIN ]] && remove_path "$FSH_GLOBAL_BIN"
  printf 'Uninstalled global fsh\n' >&2
}

uninstall_both() {
  fsh_has_local_install && uninstall_local
  fsh_has_global_install && uninstall_global
}

pick_install_target() {
  fsh_menu_defaults
  f_prompt='Install to: '
  f_height=6
  f_select \
    "$FSH_LOCAL_ROOT (local)" \
    "$FSH_GLOBAL_ROOT (system)"
}

pick_uninstall_target() {
  local -a choices=()
  fsh_has_local_install && choices+=('Uninstall local (~/fsh)')
  fsh_has_global_install && choices+=('Uninstall global (/fsh)')
  if fsh_has_local_install && fsh_has_global_install; then
    choices+=('Uninstall both')
  fi
  ((${#choices[@]} > 0)) || die 'nothing installed'
  fsh_menu_defaults
  f_prompt='Uninstall: '
  f_height=6
  f_select "${choices[@]}"
}

pick_action() {
  local -a actions=('Install')

  if fsh_has_local_install || fsh_has_global_install; then
    actions+=('Update')
    actions+=('Upgrade')
    actions+=('Uninstall')
  fi

  actions+=('Quit')

  fsh_menu_defaults
  f_prompt='Manage fsh: '
  f_height=7
  f_select "${actions[@]}"
}

resolve_install_target() {
  case "$1" in
    *'(system)'*|/fsh|system) install_global ;;
    *'(local)'*|~|home|user) install_local ;;
    *) die "unknown install target: $1" ;;
  esac
}

resolve_uninstall_target() {
  case "$1" in
    'Uninstall local (~/fsh)'|local) uninstall_local ;;
    'Uninstall global (/fsh)'|global) uninstall_global ;;
    'Uninstall both'|both) uninstall_both ;;
    *) die "unknown uninstall target: $1" ;;
  esac
}

update_local() {
  fsh_has_local_install || die 'no local install at ~/fsh'

  mkdir -p "$FSH_LOCAL_ROOT/lib"
  cp -a "$DIR"/*.sh "$FSH_LOCAL_ROOT/"
  cp -a "$DIR"/lib/* "$FSH_LOCAL_ROOT/lib/"
  rm -f "$FSH_LOCAL_ROOT/install_f.sh"
  chmod +x "$FSH_LOCAL_ROOT"/*.sh "$FSH_LOCAL_ROOT"/lib/*.sh

  printf 'Updated local installation\n' >&2
}

update_global() {
  fsh_has_global_install || die 'no global install at /fsh'

  if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die 'sudo required for system update'
    sudo cp -a "$DIR"/*.sh /fsh/
    sudo cp -a "$DIR"/lib/* /fsh/lib/
    sudo rm -f /fsh/install_f.sh
    sudo chmod +x /fsh/*.sh /fsh/lib/*.sh
  else
    cp -a "$DIR"/*.sh /fsh/
    cp -a "$DIR"/lib/* /fsh/lib/
    rm -f /fsh/install_f.sh
    chmod +x /fsh/*.sh /fsh/lib/*.sh
  fi

  printf 'Updated global installation\n' >&2
}

update_both() {
  fsh_has_local_install && update_local
  fsh_has_global_install && update_global
}

pick_update_target() {
  local -a choices=()

  fsh_has_local_install && choices+=('Update local (~/fsh)')
  fsh_has_global_install && choices+=('Update global (/fsh)')

  if fsh_has_local_install && fsh_has_global_install; then
    choices+=('Update both')
  fi

  ((${#choices[@]} > 0)) || die 'nothing installed'

  fsh_menu_defaults
  f_prompt='Update: '
  f_height=6
  f_select "${choices[@]}"
}

resolve_update_target() {
  case "$1" in
    'Update local (~/fsh)'|local|home|user)
      update_local
      ;;
    'Update global (/fsh)'|global|system)
      update_global
      ;;
    'Update both'|both)
      update_both
      ;;
    *)
      die "unknown update target: $1"
      ;;
  esac
}

upgrade() {
  command -v git >/dev/null 2>&1 || die 'git is required for upgrade'

  if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Updating repository...\n' >&2
    git -C "$DIR" pull --ff-only
    "$DIR/manage_f.sh" update both
    return
  fi

  local tmp
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN

  printf 'Downloading latest fsh...\n' >&2
  git clone --depth=1 https://github.com/arozoid/fsh.git "$tmp"

  "$tmp/manage_f.sh" update both
}

main() {
  local action target

  case ${1:-} in
    install)
      shift
      case ${1:-} in
        local|home|user|'') install_local ;;
        global|system|/) install_global ;;
        *) resolve_install_target "$1" ;;
      esac
      ;;

    update)
      shift
      case ${1:-} in
        local|home|user) update_local ;;
        global|system) update_global ;;
        both|'') update_both ;;
        *) resolve_update_target "$1" ;;
      esac
      ;;

    upgrade)
      upgrade
      ;;

    uninstall)
      shift
      case ${1:-} in
        local|home) uninstall_local ;;
        global|system) uninstall_global ;;
        both) uninstall_both ;;
        '')
          target=$(pick_uninstall_target) || exit 0
          resolve_uninstall_target "$target"
          ;;
        *)
          resolve_uninstall_target "$1"
          ;;
      esac
      ;;

    '')
      action=$(pick_action) || exit 0

      case "$action" in
        Install)
          target=$(pick_install_target) || exit 0
          resolve_install_target "$target"
          ;;

        Update)
          target=$(pick_update_target) || exit 0
          resolve_update_target "$target"
          ;;

        Upgrade)
          upgrade
          ;;

        Uninstall)
          target=$(pick_uninstall_target) || exit 0
          resolve_uninstall_target "$target"
          ;;

        Quit)
          exit 0
          ;;
      esac
      ;;

    *)
      die "usage: manage_f.sh [install [local|global] | update [local|global|both] | upgrade | uninstall [local|global|both]]"
      ;;
  esac
}

main "$@"
