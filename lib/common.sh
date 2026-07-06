#!/usr/bin/env bash
# lib/common.sh — shared bootstrap for f.sh sample scripts

FSH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FSH_DIR="$(cd "$FSH_LIB_DIR/.." && pwd)"
FSH_SCRIPT_NAME=fsh
FSH_SCRIPT_PATHS=()
FSH_SCRIPT_LABELS=()

# Load menu library once so f_* defaults exist before callers use set -u.
# shellcheck source=lib/f.sh
source "$FSH_LIB_DIR/f.sh"

die() {
  printf '%s: %s\n' "${FSH_SCRIPT_NAME:-fsh}" "$*" >&2
  exit 1
}

# Resolve a script path through symlinks (for global /bin/fsh installs).
fsh_resolve_script_dir() {
  local src=$1 dir link
  [[ -n $src ]] || return 1
  while [[ -L $src ]]; do
    link=$(readlink "$src")
    if [[ $link == /* ]]; then
      src=$link
    else
      src=$(cd "$(dirname "$src")" && pwd)/$link
    fi
  done
  dir=$(cd "$(dirname "$src")" && pwd)
  printf '%s' "$dir"
}

# Call once per script after sourcing this file.
fsh_init() {
  FSH_SCRIPT_NAME=${1:-fsh}
}

# Reset public f.sh menu variables before each f_select.
fsh_menu_defaults() {
  f_prompt='> '
  f_height=10
  f_border=0
  f_fuzzy=1
  f_smart_priority=0
  f_hints=1
  f_marker=1
  f_status=1
  f_color_prompt=$'\033[1;35m'
  f_color_query=$'\033[1;37m'
  f_color_normal=$'\033[0m'
  f_color_selected=$'\033[46;30;1m'
  f_color_border=$'\033[90m'
  f_color_match=$'\033[1;33m'
  f_color_dim=$'\033[2m'
  f_reset=$'\033[0m'
}

# Standard install / search roots (first match wins for duplicate script names).
fsh_search_dirs() {
  local -a dirs=() seen=() d base
  for d in \
    "$HOME/Documents/@project/fsh" \
    "$HOME/fsh" \
    "$HOME/Documents/fsh" \
    /fsh \
    "$FSH_DIR"; do
    [[ -d $d ]] || continue
    base=$(cd "$d" && pwd)
    [[ " ${seen[*]} " == *" $base "* ]] && continue
    seen+=("$base")
    dirs+=("$base")
  done
  ((${#dirs[@]} > 0)) || return 1
  printf '%s\n' "${dirs[@]}"
}

# Build "script.sh — description" label from a script's header comment.
fsh_script_label() {
  local script=$1 base line desc
  base=$(basename "$script")
  line=$(sed -n '2p' "$script" 2>/dev/null || true)
  [[ $line == \#!* ]] && line=$(sed -n '3p' "$script" 2>/dev/null || true)
  line=${line#\# }
  if [[ $line == "$base"* ]]; then
    desc=${line#"$base"}
    desc=${desc# — }
    desc=${desc# - }
    desc=${desc#: }
    [[ -n $desc ]] || desc='utility script'
  else
    desc=${line:-utility script}
  fi
  printf '%s — %s' "$base" "$desc"
}

# Discover top-level *.sh scripts; first search root wins for duplicate names.
fsh_discover_scripts() {
  local dir script base label
  local -a paths=() labels=() lines=()
  local -A seen=()

  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    for script in "$dir"/*.sh; do
      [[ -f $script ]] || continue
      base=$(basename "$script")
      [[ -n ${seen[$base]:-} ]] && continue
      seen[$base]=1
      script=$(cd "$(dirname "$script")" && pwd)/$base
      label=$(fsh_script_label "$script")
      lines+=("${label}"$'\t'"${script}")
    done
  done < <(fsh_search_dirs)

  ((${#lines[@]} > 0)) || return 1

  paths=()
  labels=()
  local line
  while IFS= read -r line; do
    labels+=("${line%%$'\t'*}")
    paths+=("${line#*$'\t'}")
  done < <(printf '%s\n' "${lines[@]}" | LC_ALL=C sort -f -t $'\t' -k1,1)

  FSH_SCRIPT_PATHS=("${paths[@]}")
  FSH_SCRIPT_LABELS=("${labels[@]}")
}

fsh_script_path_for() {
  local entry=$1 i
  for i in "${!FSH_SCRIPT_LABELS[@]}"; do
    if [[ ${FSH_SCRIPT_LABELS[i]} == "$entry" ]]; then
      printf '%s' "${FSH_SCRIPT_PATHS[i]}"
      return 0
    fi
  done
  return 1
}

# Install detection helpers (used by manage_f.sh).
fsh_has_local_install() {
  [[ -d $HOME/fsh/lib && -f $HOME/fsh/run.sh ]]
}

fsh_has_global_install() {
  [[ -d /fsh/lib && -f /fsh/run.sh ]]
}

fsh_alias_marker='# fsh alias (manage_f.sh)'
