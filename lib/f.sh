#!/usr/bin/env bash
# f.sh - interactive fuzzy selection menu.

f_prompt='> '
f_height=10
f_border=0
f_fuzzy=1
f_smart_priority=0
f_hints=1
f_marker=1
f_status=1
f_min_query_length=0
f_search_delay=100
f_preview_count=300
f_no_search=0

f_color_prompt=$'\033[1;35m'
f_color_query=$'\033[1;37m'
f_color_normal=$'\033[0m'
f_color_selected=$'\033[46;30;1m'
f_color_border=$'\033[90m'
f_color_match=$'\033[1;33m'
f_color_dim=$'\033[2m'
f_reset=$'\033[0m'

_F_FD_TTY_IN=''
_F_FD_TTY_OUT=''

_f_items=()
_f_filtered=()
_f_query=''
_f_cursor=0
_f_cursor_pos=0
_f_scroll=0
_f_last_key=''
_f_last_string=''
_f_display_query=''
_f_menu_shell_depth=0

_f_term_h=24
_f_term_w=80
_f_render_w=79
_f_start_row=1
_f_prompt_row=1
_f_status_row=0
_f_visible=10
_f_active=0
_f_resized=0
_f_cancelled=0
_f_tty_saved=''
_f_have_tput=0
_f_have_sort=0
_f_have_awk=0

_f_filter_tmpdir=''
_f_filter_seq=0
_f_filter_ready_seq=0
_f_filter_pid=''
_f_filter_file=''
_f_filter_pending=0
_f_filter_async_threshold=256
_f_filter_stale_pids=()

_f_search_pending_query=''
_f_search_pending_at=0

_f_source_type="array"      # array | file | dynamic
_f_items_file=""
_f_dynamic_callback=""

_f_prev_rows=()
_f_prev_row_nums=()
_f_render_rows=()
_f_render_row_nums=()

_f_normalize_ansi() {
  local s=$1
  s=${s//\\033/$'\033'}
  s=${s//\\e/$'\033'}
  printf '%s' "$s"
}

_f_init_colors() {
  f_color_prompt=$(_f_normalize_ansi "${f_color_prompt:-$'\033[1;36m'}")
  f_color_query=$(_f_normalize_ansi "${f_color_query:-$'\033[0m'}")
  f_color_normal=$(_f_normalize_ansi "${f_color_normal:-$'\033[0m'}")
  f_color_selected=$(_f_normalize_ansi "${f_color_selected:-$'\033[7m'}")
  f_color_border=$(_f_normalize_ansi "${f_color_border:-$'\033[2m'}")
  f_color_match=$(_f_normalize_ansi "${f_color_match:-$'\033[1;33m'}")
  f_color_dim=$(_f_normalize_ansi "${f_color_dim:-$'\033[2m'}")
  f_reset=$(_f_normalize_ansi "${f_reset:-$'\033[0m'}")
}

_f_tty() {
  [[ -n $_F_FD_TTY_OUT ]] || return 1
  # shellcheck disable=SC2059
  printf "$@" >&${_F_FD_TTY_OUT}
}

_f_tty_goto() {
  _f_tty $'\033[%d;%dH' "$1" "$2"
}

_f_tty_clear_eol() {
  _f_tty $'\033[K'
}

_f_tty_hide_cursor() {
  if ((_f_have_tput)); then
    tput civis >&${_F_FD_TTY_OUT} 2>/dev/null || _f_tty $'\033[?25l'
  else
    _f_tty $'\033[?25l'
  fi
}

_f_tty_show_cursor() {
  if ((_f_have_tput)); then
    tput cnorm >&${_F_FD_TTY_OUT} 2>/dev/null || _f_tty $'\033[?25h'
  else
    _f_tty $'\033[?25h'
  fi
}

_f_repeat() {
  local char=$1 count=$2 out=''
  while ((count-- > 0)); do
    out+=$char
  done
  printf '%s' "$out"
}

_f_now_ms() {
  date +%s%3N 2>/dev/null || printf '%d000' "$(date +%s)"
}

_f_update_dimensions() {
  local size h w

  if size=$(stty size </dev/tty 2>/dev/null); then
    h=${size%% *}
    w=${size##* }
    if [[ $h =~ ^[0-9]+$ && $w =~ ^[0-9]+$ ]]; then
      _f_term_h=$h
      _f_term_w=$w
    fi
  elif ((_f_have_tput)); then
    h=$(tput lines <&${_F_FD_TTY_IN} 2>/dev/null)
    w=$(tput cols <&${_F_FD_TTY_IN} 2>/dev/null)
    if [[ $h =~ ^[0-9]+$ && $w =~ ^[0-9]+$ ]]; then
      _f_term_h=$h
      _f_term_w=$w
    fi
  else
    _f_term_h=${LINES:-24}
    _f_term_w=${COLUMNS:-80}
  fi

  _f_render_w=$((_f_term_w - 1))
  ((_f_render_w < 1)) && _f_render_w=1
}

_f_cfg_border() { printf '%s' "${f_border:-0}"; }
_f_cfg_height() { printf '%s' "${f_height:-10}"; }
_f_cfg_hints() { printf '%s' "${f_hints:-1}"; }
_f_cfg_marker() { printf '%s' "${f_marker:-1}"; }
_f_cfg_prompt() { printf '%s' "${f_prompt:-'> '}"; }
_f_cfg_status() { printf '%s' "${f_status:-1}"; }
_f_cfg_fuzzy() { printf '%s' "${f_fuzzy:-1}"; }
_f_cfg_smart_priority() { printf '%s' "${f_smart_priority:-0}"; }

_f_compute_layout() {
  local requested=$(_f_cfg_height)
  local border_rows=0 status_rows=0 available

  (($(_f_cfg_border))) && border_rows=2
  if (($(_f_cfg_status))) || (($(_f_cfg_hints))); then
    status_rows=1
  fi

  available=$((_f_term_h - 1 - status_rows - border_rows))
  ((available < 1)) && available=1

  _f_visible=$requested
  ((_f_visible > 100)) && _f_visible=100
  ((_f_visible > available)) && _f_visible=$available
  ((_f_visible < 1)) && _f_visible=1

  _f_prompt_row=$_f_term_h
  if ((status_rows)); then
    _f_status_row=$((_f_term_h - 1))
  else
    _f_status_row=0
  fi
  _f_start_row=$((_f_term_h - status_rows - border_rows - _f_visible))
  ((_f_start_row < 1)) && _f_start_row=1
}

_f_tty_set_raw() {
  stty -echo -icanon -isig min 0 time 0 </dev/tty 2>/dev/null || true
}

f_init_terminal() {
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'f.sh: /dev/tty not available\n' >&2
    return 1
  fi

  local fd
  if ! { eval "exec {_F_FD_TTY_IN}</dev/tty" 2>/dev/null; }; then
    for fd in 10 11 12 13 14 198; do
      if eval "exec ${fd}</dev/tty" 2>/dev/null; then
        _F_FD_TTY_IN=$fd
        break
      fi
    done
  fi
  [[ -n $_F_FD_TTY_IN ]] || return 1

  if ! { eval "exec {_F_FD_TTY_OUT}>/dev/tty" 2>/dev/null; }; then
    for fd in 11 12 13 14 15 199; do
      [[ $fd -eq $_F_FD_TTY_IN ]] && continue
      if eval "exec ${fd}>/dev/tty" 2>/dev/null; then
        _F_FD_TTY_OUT=$fd
        break
      fi
    done
  fi
  if [[ -z $_F_FD_TTY_OUT ]]; then
    eval "exec ${_F_FD_TTY_IN}<&-"
    _F_FD_TTY_IN=''
    return 1
  fi

  _f_have_tput=0
  command -v tput >/dev/null 2>&1 && tput cols <&${_F_FD_TTY_IN} >/dev/null 2>&1 && _f_have_tput=1
  _f_have_sort=0
  command -v sort >/dev/null 2>&1 && _f_have_sort=1
  _f_have_awk=0
  command -v awk >/dev/null 2>&1 && _f_have_awk=1

  _f_fuzzy=${f_fuzzy:-1}
  _f_smart_priority=${f_smart_priority:-0}

  _f_tty_saved=$(stty -g </dev/tty 2>/dev/null) || _f_tty_saved=''
  _f_tty_set_raw
  bind 'set bind-tty-special-chars off' 2>/dev/null || true

  _f_update_dimensions
  _f_compute_layout
  _f_init_colors

  _f_tty $'\0337'
  _f_tty_hide_cursor
  _f_tty $'\033[0m'

  _f_active=1
  _f_resized=0
  _f_cancelled=0
  _f_prev_rows=()
  _f_prev_row_nums=()
}

_f_clear_rows() {
  local row
  for row in "$@"; do
    [[ $row =~ ^[0-9]+$ ]] || continue
    ((row >= 1 && row <= _f_term_h)) || continue
    _f_tty_goto "$row" 1
    _f_tty_clear_eol
  done
}

_f_filter_cleanup() {
  local pid
  for pid in "${_f_filter_stale_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n $_f_filter_pid ]]; then
    kill "$_f_filter_pid" 2>/dev/null || true
    wait "$_f_filter_pid" 2>/dev/null || true
  fi
  _f_filter_stale_pids=()
  _f_filter_pid=''
  _f_filter_file=''
  _f_filter_pending=0
  if [[ -n $_f_filter_tmpdir ]]; then
    rm -rf -- "$_f_filter_tmpdir" 2>/dev/null || true
    _f_filter_tmpdir=''
  fi
}

f_restore_terminal() {
  ((_f_active)) || return 0
  _f_active=0

  _f_filter_cleanup
  _f_clear_rows "${_f_prev_row_nums[@]}"
  _f_tty $'\033[0m'
  _f_tty $'\0338'
  _f_tty_show_cursor

  if [[ -n $_f_tty_saved ]]; then
    stty "$_f_tty_saved" </dev/tty 2>/dev/null || true
    _f_tty_saved=''
  fi

  bind 'set bind-tty-special-chars on' 2>/dev/null || true
  eval "exec ${_F_FD_TTY_IN}<&-"
  eval "exec ${_F_FD_TTY_OUT}>&-"
  _F_FD_TTY_IN=''
  _F_FD_TTY_OUT=''
  trap - WINCH INT TERM HUP QUIT EXIT
}

_f_setup_traps() {
  _f_menu_shell_depth=${BASH_SUBSHELL:-0}
  trap '_f_trap_exit' EXIT
  trap '_f_on_signal' INT TERM HUP QUIT
  trap 'f_handle_resize' WINCH
}

_f_trap_exit() {
  [[ ${BASH_SUBSHELL:-0} -eq $_f_menu_shell_depth ]] || return 0
  f_restore_terminal
}

_f_clear_traps() {
  trap - WINCH INT TERM HUP QUIT EXIT
}

f_handle_resize() {
  _f_resized=1
}

_f_on_signal() {
  _f_cancelled=1
  _f_clear_traps
  f_restore_terminal
}

_f_filter_row_score() {
  local text=$1 query_l=$2 fuzzy=$3 smart=$4
  local text_l pos qi ti score prev consec bonus c prev_c
  text_l=${text,,}
  if [[ ${text_l//"$query_l"/} != "$text_l" ]]; then
    pos=${text_l%%"$query_l"*}
    local base=0
    if ((fuzzy == 1)); then
      if ((smart == 1)); then
        base=10000000
      else
        base=2000000
      fi
    fi
    printf '%s\t%s\n' "$((base + 10000 - ${#pos}))" "$text"
    return
  fi
  (($_f_fuzzy)) || return
  qi=0; score=0; prev=-2; consec=0
  for ((ti = 0; ti < ${#text_l} && qi < ${#query_l}; ti++)); do
    if [[ ${text_l:ti:1} == "${query_l:qi:1}" ]]; then
      bonus=0
      if ((prev == ti - 1)); then
        ((consec++)); ((bonus += 2 + consec))
      else
        consec=0
      fi
      ((ti == 0)) && ((bonus += 3))
      if ((ti > 0)); then
        c=${text_l:ti-1:1}
        case $c in '/'|'-'|'_'|'.'|' '|$'\t') ((bonus += 4)) ;; esac
        prev_c=${text:ti-1:1}; c=${text:ti:1}
        [[ $prev_c =~ [a-z] && $c =~ [A-Z] ]] && ((bonus += 3))
      fi
      ((score += 1 + bonus)); prev=$ti; ((qi++))
    fi
  done
  ((qi == ${#query_l})) && printf '%s\t%s\n' "$((score * 10000 - ${#text}))" "$text"
}

_f_filter_rows() {
  local query=$1 fuzzy=$_f_fuzzy smart=$_f_smart_priority

  if ((_f_have_awk)); then
    case $_f_source_type in
      file)    cat "$_f_items_file" ;;
      dynamic) "$_f_dynamic_callback" "$query" ;;
      *)       printf '%s\n' "${_f_items[@]}" ;;
    esac | LC_ALL=C awk -v query="$query" -v fuzzy="$fuzzy" -v smart="$smart" '
      BEGIN { ql = tolower(query) }
      function fuzzy_score(text, tl,    tlen, qlen, ti, qi, score, prev, consec, bonus, p, c) {
        tlen = length(tl); qlen = length(ql)
        qi = 1; score = 0; prev = -2; consec = 0
        for (ti = 1; ti <= tlen && qi <= qlen; ti++) {
          if (substr(tl, ti, 1) == substr(ql, qi, 1)) {
            bonus = 0
            if (prev == ti - 1) { consec++; bonus += 2 + consec } else { consec = 0 }
            if (ti == 1) bonus += 3
            if (ti > 1) {
              p = substr(tl, ti - 1, 1)
              if (p ~ /[\/._ \t-]/) bonus += 4
              p = substr(text, ti - 1, 1); c = substr(text, ti, 1)
              if (p ~ /[a-z]/ && c ~ /[A-Z]/) bonus += 3
            }
            score += 1 + bonus
            prev = ti
            qi++
          }
        }
        return qi > qlen ? score * 10000 - length(text) : -1
      }
      {
        text_l = tolower($0)
        pos = index(text_l, ql)
        has_sub = pos > 0
        sub_score = has_sub ? 10001 - pos : 0
        if (fuzzy == 0) {
          if (has_sub) print sub_score "\t" $0
          next
        }
        if (has_sub) {
          print (smart == 1 ? 10000000 + sub_score : 2000000 + sub_score) "\t" $0
          next
        }
        fz = fuzzy_score($0, text_l)
        if (fz >= 0) print fz "\t" $0
      }
    '
    return
  fi

  local text query_l=${query,,}
  if [[ $_f_source_type == "file" ]]; then
    while IFS= read -r text; do
      _f_filter_row_score "$text" "$query_l" "$fuzzy" "$smart"
    done < "$_f_items_file"
  elif [[ $_f_source_type == "dynamic" ]]; then
    while IFS= read -r text; do
      _f_filter_row_score "$text" "$query_l" "$fuzzy" "$smart"
    done < <("$_f_dynamic_callback" "$query")
  else
    for text in "${_f_items[@]}"; do
      _f_filter_row_score "$text" "$query_l" "$fuzzy" "$smart"
    done
  fi
}

f_filter_items() {
  local -a _f_new_filtered=()

  if ((f_min_query_length > 0 && ${#_f_query} < f_min_query_length)); then
    case $_f_source_type in
      file)     mapfile -t _f_new_filtered < <(head -n "$f_preview_count" "$_f_items_file") ;;
      dynamic)  mapfile -t _f_new_filtered < <("$_f_dynamic_callback" "" | head -n "$f_preview_count") ;;
      *)        _f_new_filtered=("${_f_items[@]}")
                ((${#_f_new_filtered[@]} > f_preview_count)) && _f_new_filtered=("${_f_new_filtered[@]:0:f_preview_count}") ;;
    esac
    _f_filtered=("${_f_new_filtered[@]}")
    return
  fi

  if ((f_no_search)); then
    case $_f_source_type in
      file)     mapfile -t _f_new_filtered < "$_f_items_file" ;;
      dynamic)  mapfile -t _f_new_filtered < <("$_f_dynamic_callback" "$_f_query") ;;
      *)        _f_new_filtered=("${_f_items[@]}") ;;
    esac
    _f_filtered=("${_f_new_filtered[@]}")
    return
  fi

  if [[ -z $_f_query ]]; then
    case $_f_source_type in
      file)     mapfile -t _f_new_filtered < <(head -n "$f_preview_count" "$_f_items_file") ;;
      dynamic)  mapfile -t _f_new_filtered < <("$_f_dynamic_callback" "" | head -n "$f_preview_count") ;;
      *)        _f_new_filtered=("${_f_items[@]}")
                ((${#_f_new_filtered[@]} > f_preview_count)) && _f_new_filtered=("${_f_new_filtered[@]:0:f_preview_count}") ;;
    esac
    _f_filtered=("${_f_new_filtered[@]}")
    return
  fi

  local rows=() row
  if ((_f_have_sort)); then
    mapfile -t rows < <(_f_filter_rows "$_f_query" | sort -t $'\t' -k1,1nr | head -n "$f_preview_count")
  else
    mapfile -t rows < <(_f_filter_rows "$_f_query" | head -n "$f_preview_count")
  fi

  for row in "${rows[@]}"; do
    [[ $row == *$'\t'* ]] || continue
    _f_new_filtered+=("${row#*$'\t'}")
  done

  _f_filtered=("${_f_new_filtered[@]}")
}

_f_filter_ensure_tmpdir() {
  [[ -n $_f_filter_tmpdir ]] && return 0
  if command -v mktemp >/dev/null 2>&1; then
    _f_filter_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fsh.XXXXXX" 2>/dev/null) || _f_filter_tmpdir=''
  fi
  if [[ -z $_f_filter_tmpdir ]]; then
    _f_filter_tmpdir="${TMPDIR:-/tmp}/fsh.${BASHPID:-$$}"
    mkdir -p -- "$_f_filter_tmpdir" 2>/dev/null || return 1
  fi
}

_f_filter_worker() {
  local seq=$1 query=$2 file=$3 tmp
  _f_query=$query
  f_filter_items
  tmp="${file}.tmp.${BASHPID:-$$}"
  printf '%s\n' "${_f_filtered[@]}" >"$tmp" && mv -f -- "$tmp" "$file"
}

_f_filter_reap_stale() {
  local pid
  local -a live=()
  for pid in "${_f_filter_stale_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      live+=("$pid")
    else
      wait "$pid" 2>/dev/null || true
    fi
  done
  _f_filter_stale_pids=("${live[@]}")
}

_f_filter_start_async() {
  local seq=$1 query=$2
  _f_filter_ensure_tmpdir || return 1
  _f_filter_file="$_f_filter_tmpdir/filter.$seq"
  _f_filter_pending=1
  _f_filter_worker "$seq" "$query" "$_f_filter_file" &
  _f_filter_pid=$!
}

_f_filter_request() {
  local query=$1
  _f_filter_seq=$((_f_filter_seq + 1))
  _f_query=$query
  _f_cursor=0
  _f_scroll=0
  _f_prev_rows=()
  _f_prev_row_nums=()

  if [[ -n $_f_filter_pid ]]; then
    kill "$_f_filter_pid" 2>/dev/null || true
    _f_filter_stale_pids+=("$_f_filter_pid")
    _f_filter_pid=''
  fi

  if [[ $_f_source_type != "array" || -z $query || ${#_f_items[@]} -le $_f_filter_async_threshold ]]; then
    f_filter_items
    _f_filter_ready_seq=$_f_filter_seq
    _f_filter_pending=0
    return
  fi

  _f_filter_start_async "$_f_filter_seq" "$query" || {
    f_filter_items
    _f_filter_ready_seq=$_f_filter_seq
    _f_filter_pending=0
  }
}

_f_filter_poll() {
  local pid=$_f_filter_pid file=$_f_filter_file seq=$_f_filter_seq
  _f_filter_reap_stale

  [[ -n $pid ]] || return 1
  kill -0 "$pid" 2>/dev/null && return 1

  wait "$pid" 2>/dev/null || true
  _f_filter_pid=''

  if [[ -f $file ]]; then
    mapfile -t _f_filtered < "$file"
    rm -f -- "$file" 2>/dev/null || true
    _f_filter_ready_seq=$seq
    _f_filter_pending=0
    _f_cursor=0
    _f_scroll=0
    return 0
  fi

  return 1
}

_f_plain_truncate() {
  local s=$1 max=$2
  if ((${#s} <= max)); then
    _f_last_string=$s
  elif ((max <= 1)); then
    _f_last_string=${s:0:max}
  else
    _f_last_string="${s:0:max-1}…"
  fi
}

_f_contains_ci() {
  local hay=${1,,} needle=${2,,}
  [[ -z $needle || ${hay//"$needle"/} != "$hay" ]]
}

_f_sub_pos_ci() {
  local text_l=${1,,} query_l=${2,,} prefix
  [[ -n $query_l && ${text_l//"$query_l"/} != "$text_l" ]] || return 1
  prefix=${text_l%%"$query_l"*}
  printf '%s' "${#prefix}"
}

_f_highlight() {
  local query=$1 text=$2
  local qlen=${#query}
  local pos end ql tl out='' ti=0 qi=0 ch in_match=0
  local c_match=${f_color_match:-$'\033[1m'} c_reset=${f_reset:-$'\033[0m'} c_normal=${f_color_normal:-$'\033[0m'}

  if ((qlen == 0)); then
    _f_last_string=$text
    return
  fi

  if ((!$_f_fuzzy)) || _f_contains_ci "$text" "$query"; then
    if pos=$(_f_sub_pos_ci "$text" "$query"); then
      end=$((pos + qlen))
      _f_last_string="${text:0:pos}${c_match}${text:pos:qlen}${c_reset}${c_normal}${text:end}${c_reset}"
      return
    fi
  fi

  ql=${query,,}; tl=${text,,}
  while ((ti < ${#text})); do
    ch=${text:ti:1}
    if ((qi < qlen)) && [[ ${tl:ti:1} == "${ql:qi:1}" ]]; then
      if ((!in_match)); then out+=$c_match; in_match=1; fi
      out+=$ch
      ((qi++))
    else
      if ((in_match)); then out+="${c_reset}${c_normal}"; in_match=0; fi
      out+=$ch
    fi
    ((ti++))
  done
  ((in_match)) && out+="${c_reset}${c_normal}"
  _f_last_string=$out
}

_f_sync_scroll() {
  local total=${#_f_filtered[@]} max_scroll
  if ((total == 0)); then
    _f_cursor=0; _f_scroll=0; return
  fi
  ((_f_cursor < 0)) && _f_cursor=0
  ((_f_cursor >= total)) && _f_cursor=$((total - 1))
  if ((_f_cursor < _f_scroll)); then
    _f_scroll=$_f_cursor
  elif ((_f_cursor >= _f_scroll + _f_visible)); then
    _f_scroll=$((_f_cursor - _f_visible + 1))
  fi
  max_scroll=$((total - _f_visible))
  ((max_scroll < 0)) && max_scroll=0
  ((_f_scroll > max_scroll)) && _f_scroll=$max_scroll
  ((_f_scroll < 0)) && _f_scroll=0
}

_f_border_line() {
  local kind=$1 has_more=$2 c_border=${f_color_border:-$'\033[90m'} c_reset=${f_reset:-$'\033[0m'}
  local w=$_f_render_w fill
  if ((w <= 1)); then
    printf '%s%s%s' "$c_border" "$kind" "$c_reset"
    return
  fi
  case $kind:$has_more in
    top:1)
      if ((w >= 4)); then
        fill=$(_f_repeat '─' "$((w - 4))")
        printf '%s┌─▲%s┐%s' "$c_border" "$fill" "$c_reset"
      else
        fill=$(_f_repeat '─' "$((w - 2))")
        printf '%s┌%s┐%s' "$c_border" "$fill" "$c_reset"
      fi
      ;;
    bottom:1)
      if ((w >= 4)); then
        fill=$(_f_repeat '─' "$((w - 4))")
        printf '%s└─▼%s┘%s' "$c_border" "$fill" "$c_reset"
      else
        fill=$(_f_repeat '─' "$((w - 2))")
        printf '%s└%s┘%s' "$c_border" "$fill" "$c_reset"
      fi
      ;;
    top:*)
      fill=$(_f_repeat '─' "$((w - 2))")
      printf '%s┌%s┐%s' "$c_border" "$fill" "$c_reset"
      ;;
    bottom:*)
      fill=$(_f_repeat '─' "$((w - 2))")
      printf '%s└%s┘%s' "$c_border" "$fill" "$c_reset"
      ;;
  esac
}

_f_build_rows() {
  local total=${#_f_filtered[@]} border=$(_f_cfg_border) marker=$(_f_cfg_marker)
  local row=$_f_start_row r idx item plain rendered prefix line
  local prefix_w inner scroll_up=0 scroll_down=0
  local c_border=${f_color_border:-$'\033[90m'} c_reset=${f_reset:-$'\033[0m'}
  local c_normal=${f_color_normal:-$'\033[0m'} c_selected=${f_color_selected:-$'\033[7m'}
  local c_dim=${f_color_dim:-$'\033[2m'} c_prompt=${f_color_prompt:-$'\033[1;35m'} c_query=${f_color_query:-$'\033[1;37m'}
  local prompt display_query max_query status_text='' hints='' status_line

  _f_render_rows=()
  _f_render_row_nums=()

  _f_sync_scroll
  ((total > _f_visible && _f_scroll > 0)) && scroll_up=1
  ((total > _f_visible && _f_scroll + _f_visible < total)) && scroll_down=1

  if ((border)); then
    _f_render_rows[$row]=$(_f_border_line top "$scroll_up")
    _f_render_row_nums+=("$row")
    ((row++))
  fi

  for ((r = 0; r < _f_visible; r++)); do
    prefix=''
    prefix_w=0
    if ((border)); then
      prefix="${c_border}│${c_reset} "
      prefix_w=2
    fi
    if ((marker)); then
      idx=$((_f_scroll + r))
      if ((idx == _f_cursor && idx < total)); then
        prefix+="${f_color_match:-$'\033[1;33m'}▸ ${c_reset}"
      else
        prefix+='  '
      fi
      ((prefix_w += 2))
    fi

    inner=$((_f_render_w - prefix_w))
    ((inner < 1)) && inner=1
    idx=$((_f_scroll + r))
    line=$prefix
    if ((idx < total)); then
      item=${_f_filtered[idx]}
      _f_plain_truncate "$item" "$inner"
      plain=$_f_last_string
      if ((f_no_search)); then
        rendered=$plain
      else
        _f_highlight "$_f_query" "$plain"
        rendered=$_f_last_string
      fi
      if ((idx == _f_cursor)); then
        line+="${c_selected}${rendered}${c_reset}"
      else
        line+="${c_normal}${rendered}${c_reset}"
      fi
    fi
    _f_render_rows[$row]=$line
    _f_render_row_nums+=("$row")
    ((row++))
  done

  if ((border)); then
    _f_render_rows[$row]=$(_f_border_line bottom "$scroll_down")
    _f_render_row_nums+=("$row")
  fi

  if ((_f_status_row > 0)); then
    if (($(_f_cfg_status))); then
      if ((_f_filter_pending)); then
        status_text='searching...'
      elif ((f_min_query_length > 0 && ${#_f_query} < f_min_query_length)); then
        if ((${#_f_query} == 0)); then
          status_text="type at least $f_min_query_length chars · $total item$([[ $total -eq 1 ]] || echo s)"
        else
          status_text="type at least $f_min_query_length chars (${#_f_query}/$f_min_query_length) · $total item$([[ $total -eq 1 ]] || echo s)"
        fi
      elif ((f_no_search)); then
        status_text="$total item$([[ $total -eq 1 ]] || echo s)"
      elif ((${#_f_query} > 0)); then
        if ((total == 0)); then status_text='no matches'; else status_text="$((_f_cursor + 1))/$total"; fi
      else
        status_text="$total item$([[ $total -eq 1 ]] || echo s)"
      fi
      if ((total > _f_visible)); then
        local above=$_f_scroll below=$((total - _f_scroll - _f_visible))
        ((above > 0)) && status_text+=" · ▲$above"
        ((below > 0)) && status_text+=" · ▼$below"
      fi
    fi
    if (($(_f_cfg_hints))); then
      hints='↑↓ move · enter select · esc cancel'
      [[ -n $status_text ]] && hints="  ·  $hints"
    fi
    _f_plain_truncate "${status_text}${hints}" "$_f_render_w"
    status_line=$_f_last_string
    _f_render_rows[$_f_status_row]="${c_dim}${status_line}${c_reset}"
    _f_render_row_nums+=("$_f_status_row")
  fi

  prompt=$(_f_cfg_prompt)
  max_query=$((_f_render_w - ${#prompt} - 3))
  ((max_query < 0)) && max_query=0
  if ((${#_f_query} > max_query)); then
    if ((max_query > 1)); then
      display_query="…${_f_query: -$((max_query - 1))}"
    else
      display_query=''
    fi
  else
    display_query=$_f_query
  fi
  _f_display_query=$display_query
  local cursor_display=$_f_cursor_pos
  ((cursor_display > ${#display_query})) && cursor_display=${#display_query}
  if ((${#_f_query} > 0)); then
    local before=${display_query:0:cursor_display}
    local after=${display_query:cursor_display}
    _f_render_rows[$_f_prompt_row]="${c_prompt}${prompt}${c_reset} ${c_query}${before}${c_reset}│${c_query}${after}${c_reset}"
  else
    _f_render_rows[$_f_prompt_row]="${c_prompt}${prompt}${c_reset} ${c_query}${c_reset}│${c_reset}"
  fi
  _f_render_row_nums+=("$_f_prompt_row")
}

f_move_to_bottom() {
  local prompt=$(_f_cfg_prompt)
  local col=$((${#prompt} + ${#_f_display_query} + 2))
  ((col > _f_render_w)) && col=$_f_render_w
  ((col < 1)) && col=1
  _f_tty_goto "$_f_prompt_row" "$col"
}

f_render() {
  _f_update_dimensions
  _f_compute_layout

  # Clear everything in the terminal above the selection box to prevent stacked borders/scrolling artifacts.
  if ((_f_start_row > 1)); then
    _f_tty_goto "$((_f_start_row - 1))" "$_f_term_w"
    _f_tty $'\033[1J'
  fi

  _f_tty_hide_cursor

  local -A seen=()
  local row line prev

  _f_build_rows

  for row in "${_f_render_row_nums[@]}"; do
    seen[$row]=1
    line=${_f_render_rows[row]}
    prev=${_f_prev_rows[row]-}
    if [[ ${_f_prev_rows[row]+set} != set || $prev != "$line" ]]; then
      _f_tty_goto "$row" 1
      _f_tty '%s' "$line"
      _f_tty_clear_eol
    fi
  done

  for row in "${_f_prev_row_nums[@]}"; do
    if [[ -z ${seen[$row]:-} ]]; then
      _f_tty_goto "$row" 1
      _f_tty_clear_eol
      unset "_f_prev_rows[$row]"
    fi
  done

  _f_prev_rows=()
  for row in "${_f_render_row_nums[@]}"; do
    _f_prev_rows[$row]=${_f_render_rows[row]}
  done
  _f_prev_row_nums=("${_f_render_row_nums[@]}")
  f_move_to_bottom
}

f_render_prompt_status() {
  f_render
}

_f_key_is_enter() {
  local byte=$1 ord
  [[ -n $byte ]] || return 1
  ord=$(printf '%d' "'$byte")
  ((ord == 13 || ord == 10))
}

_f_read_byte() {
  local _var=$1 _timeout=${2:-}
  if [[ -n $_timeout ]]; then
    IFS= read -rsN1 -t "$_timeout" -u "$_F_FD_TTY_IN" "$_var" 2>/dev/null
  else
    IFS= read -rsN1 -u "$_F_FD_TTY_IN" "$_var" 2>/dev/null
  fi
}

f_read_key() {
  local timeout=${1:-} k k1 k2 k3
  _f_last_key=''

  if [[ -n $timeout ]]; then
    _f_read_byte k "$timeout" || return 1
  else
    _f_read_byte k || return 1
  fi

  if _f_key_is_enter "$k"; then
    _f_last_key='enter'
    return 0
  fi

  case $k in
    $'\x01') _f_last_key='ctrl-a' ;;
    $'\x03') _f_last_key='ctrl-c' ;;
    $'\x04') _f_last_key='ctrl-d' ;;
    $'\x05') _f_last_key='ctrl-e' ;;
    $'\x1c') _f_last_key='ctrl-\\' ;;
    $'\x7f'|$'\b') _f_last_key='backspace' ;;
    $'\x1b')
      _f_read_byte k1 0.03 || k1=''
      _f_read_byte k2 0.03 || k2=''
      case "$k1$k2" in
        '[A') _f_last_key='up' ;;
        '[B') _f_last_key='down' ;;
        '[C') _f_last_key='right' ;;
        '[D') _f_last_key='left' ;;
        'OA') _f_last_key='up' ;;
        'OB') _f_last_key='down' ;;
        'OC') _f_last_key='right' ;;
        'OD') _f_last_key='left' ;;
        '[3') _f_read_byte k3 0.03; [[ $k3 == '~' ]] && _f_last_key='delete' ;;
      esac
      if [[ -z $_f_last_key ]]; then
        _f_last_key='esc'
      fi
      ;;
    '')
      return 1
      ;;
    *)
      if [[ $k == [[:print:]] ]]; then
        _f_last_key="char:$k"
      else
        _f_last_key='unknown'
      fi
      ;;
  esac
  return 0
}

f_select_file() {
  [[ $# -eq 1 ]] || { printf 'f.sh: f_select_file: exactly 1 argument expected, got %d\n' "$#" >&2; return 1; }
  [[ -f $1 ]] || { printf 'f.sh: f_select_file: file not found: %s\n' "$1" >&2; return 1; }

  _f_source_type="file"
  _f_items_file=$1
  _f_dynamic_callback=""
  _f_items=()

  f_select
}

f_select_dynamic() {
  [[ $# -eq 1 ]] || { printf 'f.sh: f_select_dynamic: exactly 1 argument expected, got %d\n' "$#" >&2; return 1; }
  declare -F "$1" >/dev/null 2>&1 || { printf 'f.sh: f_select_dynamic: function not found: %s\n' "$1" >&2; return 1; }

  _f_source_type="dynamic"
  _f_dynamic_callback=$1
  _f_items_file=""
  _f_items=()

  f_select
}

f_select() {
  if (("$#" > 0)); then
    _f_items=("$@")
    _f_source_type="array"
    _f_items_file=""
    _f_dynamic_callback=""
  elif [[ $_f_source_type == "array" && ${#_f_items[@]} -eq 0 ]]; then
    printf 'f.sh: f_select: no items provided\n' >&2
    return 1
  fi

  _f_query=''
  _f_cursor=0
  _f_cursor_pos=0
  _f_scroll=0
  _f_cancelled=0
  _f_filter_seq=0
  _f_filter_ready_seq=0
  _f_filter_pending=0
  _f_filter_pid=''
  _f_filter_stale_pids=()
  _f_search_pending_query=''
  _f_search_pending_at=0

  f_init_terminal || return 1
  _f_setup_traps

  local key keychar selected
  _f_filter_request ''
  f_render

  while true; do
    if ((_f_resized)); then
      _f_resized=0
      _f_prev_rows=()
      _f_prev_row_nums=()
      f_render
    fi

    if _f_filter_poll; then
      f_render
    fi

    if ((_f_search_pending_at > 0)); then
      if (($(_f_now_ms) - _f_search_pending_at >= f_search_delay)); then
        _f_filter_request "$_f_search_pending_query"
        _f_search_pending_query=''
        _f_search_pending_at=0
        f_render
      fi
    fi

    ((_f_cancelled)) && return 1

    if ! f_read_key 0.03; then
      continue
    fi
    key=$_f_last_key

    case $key in
      up)
        ((_f_cursor > 0)) && ((_f_cursor--))
        f_render
        ;;
      down)
        if ((${#_f_filtered[@]} > 0)); then
          ((_f_cursor < ${#_f_filtered[@]} - 1)) && ((_f_cursor++))
        fi
        f_render
        ;;
      left)
        ((_f_cursor_pos > 0)) && ((_f_cursor_pos--))
        f_render
        ;;
      right)
        ((_f_cursor_pos < ${#_f_query})) && ((_f_cursor_pos++))
        f_render
        ;;
      home|ctrl-a)
        _f_cursor_pos=0
        f_render
        ;;
      end|ctrl-e)
        _f_cursor_pos=${#_f_query}
        f_render
        ;;
      backspace)
        if ((_f_cursor_pos > 0)); then
          _f_query="${_f_query:0:_f_cursor_pos-1}${_f_query:_f_cursor_pos}"
          ((_f_cursor_pos--))
          _f_search_pending_query=$_f_query
          _f_search_pending_at=$(_f_now_ms)
          f_render
        fi
        ;;
      delete)
        if ((_f_cursor_pos < ${#_f_query})); then
          _f_query="${_f_query:0:_f_cursor_pos}${_f_query:_f_cursor_pos+1}"
          _f_search_pending_query=$_f_query
          _f_search_pending_at=$(_f_now_ms)
          f_render
        fi
        ;;
      char:*)
        keychar=${key#char:}
        _f_query="${_f_query:0:_f_cursor_pos}${keychar}${_f_query:_f_cursor_pos}"
        ((_f_cursor_pos++))
        _f_search_pending_query=$_f_query
        _f_search_pending_at=$(_f_now_ms)
        f_render
        ;;
      enter)
        if ((_f_search_pending_at > 0)); then
          _f_filter_request "$_f_search_pending_query"
          _f_search_pending_query=''
          _f_search_pending_at=0
        fi
        if ((_f_filter_pending)); then
          while ((_f_filter_pending)); do
            if _f_filter_poll; then
              f_render
              break
            fi
            if ((_f_cancelled)); then return 1; fi
            if ! f_read_key 0.05; then
              continue
            fi
            case $_f_last_key in
              esc|ctrl-c|ctrl-d|ctrl-\\) return 1 ;;
            esac
          done
        fi
        if ((${#_f_filtered[@]} > 0)); then
          selected=${_f_filtered[_f_cursor]}
          _f_clear_traps
          f_restore_terminal
          printf '%s\n' "$selected"
          return 0
        fi
        ;;
      esc|ctrl-c|ctrl-d|ctrl-\\)
        _f_clear_traps
        f_restore_terminal
        return 1
        ;;
    esac
  done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  fruits=(Apple Apricot Banana Blackberry Blueberry Cherry Cranberry Date Fig Grape Grapefruit Kiwi Lemon Lime Mango Melon Nectarine Orange Papaya Peach Pear Pineapple Plum Pomegranate Raspberry Strawberry Watermelon)
  f_prompt='Pick a fruit: '
  f_height=8
  f_border=1
  if choice=$(f_select "${fruits[@]}"); then
    printf 'You selected: %s\n' "$choice"
  else
    printf 'Selection cancelled.\n' >&2
    exit 1
  fi
fi
