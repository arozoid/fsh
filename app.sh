#!/usr/bin/env bash
# app.sh — launch desktop applications from .desktop entries

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"
fsh_init app.sh

build_desktop_dirs() {
  local -a dirs=() seen=() d base
  for d in \
    "$HOME/.local/share/applications" \
    "$HOME/.local/share/flatpak/exports/share/applications" \
    "$HOME/.nix-profile/share/applications" \
    "$HOME/.nix-profile/var/lib/flatpak/exports/share/applications" \
    /var/lib/flatpak/exports/share/applications \
    /var/lib/snapd/desktop/applications \
    /usr/local/share/applications \
    /usr/share/applications; do
    [[ -d $d ]] || continue
    base=$(cd "$d" && pwd)
    [[ " ${seen[*]} " == *" $base "* ]] && continue
    seen+=("$base")
    dirs+=("$base")
  done

  if [[ -n ${XDG_DATA_DIRS:-} ]]; then
    local x
    IFS=':' read -ra xdg <<<"$XDG_DATA_DIRS"
    for x in "${xdg[@]}"; do
      [[ -d $x/applications ]] || continue
      base=$(cd "$x/applications" && pwd)
      [[ " ${seen[*]} " == *" $base "* ]] && continue
      seen+=("$base")
      dirs+=("$base")
    done
  fi

  ((${#dirs[@]} > 0)) || return 1
  printf '%s\n' "${dirs[@]}"
}

desktop_visible() {
  local file=$1
  local nodisplay hidden
  nodisplay=$(grep -m1 '^NoDisplay=' "$file" 2>/dev/null | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
  hidden=$(grep -m1 '^Hidden=' "$file" 2>/dev/null | cut -d= -f2- | tr '[:upper:]' '[:lower:]')
  [[ $nodisplay == true || $hidden == true ]] && return 1
  return 0
}

desktop_name() {
  local file=$1 name generic
  name=$(grep -m1 '^Name=' "$file" 2>/dev/null | cut -d= -f2-)
  generic=$(grep -m1 '^GenericName=' "$file" 2>/dev/null | cut -d= -f2-)
  if [[ -n $name && -n $generic && $name != "$generic" ]]; then
    printf '%s (%s)' "$name" "$generic"
  else
    printf '%s' "${name:-$(basename "$file" .desktop)}"
  fi
}

app_source_tag() {
  case "$1" in
    *flatpak*) printf 'flatpak' ;;
    *snapd*) printf 'snap' ;;
    "$HOME"/*) printf 'local' ;;
    *) printf 'system' ;;
  esac
}

_flatpak_entries() {
  local app id name
  flatpak list --app --columns=application 2>/dev/null || return 1
}

_snap_entries() {
  local name desktop
  snap list 2>/dev/null | awk 'NR>1 {print $1}' | while IFS= read -r name; do
    for desktop in "/snap/$name/current/meta/gui"/*.desktop; do
      [[ -f $desktop ]] && printf '%s\n' "$desktop"
    done
  done
}

list_apps() {
  local dir file label source
  local -a entries=() lines=()
  local -A label_count=()

  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    while IFS= read -r -d '' file; do
      desktop_visible "$file" || continue
      label=$(desktop_name "$file")
      [[ -n $label ]] || continue
      entries+=("$label"$'\t'"$file")
      ((label_count[$label]++))
    done < <(find "$dir" -name '*.desktop' -type f -print0 2>/dev/null)
  done < <(build_desktop_dirs)

  while IFS= read -r app; do
    [[ -n $app ]] || continue
    for dir in "$HOME/.local/share/flatpak/exports/share/applications" /var/lib/flatpak/exports/share/applications; do
      file="$dir/$app.desktop"
      if [[ -f $file ]]; then
        desktop_visible "$file" || continue
        label=$(desktop_name "$file")
        [[ -n $label ]] || continue
        entries+=("$label"$'\t'"$file")
        ((label_count[$label]++))
        break
      fi
    done
  done < <(flatpak list --app --columns=application 2>/dev/null || true)

  local snap_desktop
  while IFS= read -r snap_desktop; do
    [[ -f $snap_desktop ]] || continue
    desktop_visible "$snap_desktop" || continue
    label=$(desktop_name "$snap_desktop")
    [[ -n $label ]] || continue
    entries+=("$label"$'\t'"$snap_desktop")
    ((label_count[$label]++))
  done < <(_snap_entries)

  ((${#entries[@]} > 0)) || return 1

  local entry
  for entry in "${entries[@]}"; do
    label=${entry%%$'\t'*}
    file=${entry#*$'\t'}
    if ((${label_count[$label]} > 1)); then
      source=$(app_source_tag "$file")
      label="$label [$source]"
    fi
    lines+=("${label}"$'\t'"${file}")
  done

  LC_ALL=C sort -f -t $'\t' -k1,1 <<<"$(printf '%s\n' "${lines[@]}")"
}

pick_app() {
  local -a labels=() files=() row label file
  while IFS=$'\t' read -r label file; do
    labels+=("$label")
    files+=("$file")
  done < <(list_apps)
  ((${#labels[@]} > 0)) || die 'no desktop applications found'

  fsh_menu_defaults
  f_prompt='application: '
  f_height=15
  f_border=1
  label=$(f_select "${labels[@]}") || return 1

  local i
  for i in "${!labels[@]}"; do
    if [[ ${labels[i]} == "$label" ]]; then
      printf '%s' "${files[i]}"
      return 0
    fi
  done
  return 1
}

launch_app() {
  local file=$1 id exec flatpak_id
  id=$(basename "$file" .desktop)

  if command -v gtk-launch >/dev/null 2>&1; then
    gtk-launch "$id" >/dev/null 2>&1 && return 0
  fi
  if command -v gio >/dev/null 2>&1; then
    gio launch "$file" >/dev/null 2>&1 && return 0
  fi
  if command -v dex >/dev/null 2>&1; then
    dex "$file" >/dev/null 2>&1 & disown
    return 0
  fi

  flatpak_id=$(grep -m1 '^X-Flatpak=' "$file" 2>/dev/null | cut -d= -f2-)
  if [[ -n $flatpak_id ]] && command -v flatpak >/dev/null 2>&1; then
    flatpak run "$flatpak_id" >/dev/null 2>&1 & disown
    return 0
  fi

  exec=$(grep -m1 '^Exec=' "$file" 2>/dev/null | cut -d= -f2-)
  [[ -n $exec ]] || die "no Exec= in $file"
  exec=${exec%% ;*}
  exec=$(printf '%s' "$exec" | sed -E 's/%[fFuUdDnNickvm]//g; s/[[:space:]]+/ /g; s/^ //; s/ $//')
  # shellcheck disable=SC2086
  nohup $exec >/dev/null 2>&1 &
}

main() {
  local file
  while true; do
    file=$(pick_app) || exit 0
    printf 'launching %s\n' "$(desktop_name "$file")" >&2
    launch_app "$file"

    fsh_menu_defaults
    f_prompt='next: '
    f_height=5
    case "$(f_select 'launch another' 'quit' || echo quit)" in
      'launch another') ;;
      *) exit 0 ;;
    esac
  done
}

main "$@"
