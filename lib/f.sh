#!/usr/bin/env bash
# f.sh — interactive fuzzy selection menu (fzf-inspired, bash with optional awk/sort acceleration)
#
# Usage:
#   source /path/to/lib/f.sh
#   selection=$(f_select "${items[@]}") || echo "cancelled"
#
# Requires bash 4+ and a controlling terminal (/dev/tty).

# ---------------------------------------------------------------------------
# Configuration (override before calling f_select)
# ---------------------------------------------------------------------------

f_prompt='> '
f_height=10
f_border=0
f_fuzzy=1
f_smart_priority=0   # when 1: normal (substring) hits always rank above fuzzy-only hits
f_hints=1
f_marker=1
f_status=1

f_color_prompt=$'\033[1;35m'       # bold magenta
f_color_query=$'\033[1;37m'         # bold white
f_color_normal=$'\033[0m'
f_color_selected=$'\033[46;30;1m'   # bold cyan bg, black text
f_color_border=$'\033[90m'           # gray
f_color_match=$'\033[1;33m'         # bold yellow
f_color_dim=$'\033[2m'              # dim (status / hints)

f_reset=$'\033[0m'

# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

_F_FD_TTY_IN=''
_F_FD_TTY_OUT=''

_f_items=()
_f_items_lower=()
_f_filtered=()
_f_query=''
_f_query_lower=''
_f_cursor=0
_f_scroll=0
_f_last_score=0
_f_last_key=''
_f_last_string=''
_f_menu_shell_depth=0

_f_term_h=24
_f_term_w=80
_f_start_row=1
_f_prompt_row=1
_f_status_row=1
_f_ui_height=0
_f_active=0
_f_resized=0
_f_cancelled=0
_f_tty_saved=''
_f_have_tput=0
_f_have_sort=0
_f_have_awk=0

_f_filter_tmpdir=''
_f_filter_request_file=''
_f_filter_request_seq=0
_f_filter_ready_seq=0
_f_filter_worker_seq=0
_f_filter_worker_pid=''
_f_filter_worker_pids=()
_f_filter_worker_file=''
_f_filter_pending=0
_f_filter_async_threshold=256

# ---------------------------------------------------------------------------
# Low-level TTY output (always writes to /dev/tty, never stdout)
# ---------------------------------------------------------------------------

# Expand literal \033 / \e in user-supplied color strings to real ESC bytes.
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
  if [[ -z $_F_FD_TTY_OUT ]]; then
    return 1
  fi
  # shellcheck disable=SC2059
  printf "$@" >&${_F_FD_TTY_OUT}
}

_f_tty_clear_eol() {
  _f_tty $'\033[K'
}

# Move cursor to 1-based row/col on the terminal
_f_tty_goto() {
  _f_tty $'\033[%d;%dH' "$1" "$2"
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

# ---------------------------------------------------------------------------
# Terminal ownership
# ---------------------------------------------------------------------------

# Refresh _f_term_h / _f_term_w from the controlling terminal.
_f_update_dimensions() {
  local size h w

  if size=$(stty size <&${_F_FD_TTY_IN} 2>/dev/null); then
    h=${size%% *}
    w=${size##* }
    if [[ $h =~ ^[0-9]+$ && $w =~ ^[0-9]+$ ]]; then
      _f_term_h=$h
      _f_term_w=$w
      return 0
    fi
  fi

  if ((_f_have_tput)); then
    h=$(tput lines <&${_F_FD_TTY_IN} 2>/dev/null)
    w=$(tput cols <&${_F_FD_TTY_IN} 2>/dev/null)
    if [[ $h =~ ^[0-9]+$ && $w =~ ^[0-9]+$ ]]; then
      _f_term_h=$h
      _f_term_w=$w
      return 0
    fi
  fi

  _f_term_h=${LINES:-24}
  _f_term_w=${COLUMNS:-80}
}

# Compute 1-based layout: prompt on the last terminal row, results above it.
_f_cfg_border() { printf '%s' "${f_border:-0}"; }
_f_cfg_height() { printf '%s' "${f_height:-10}"; }
_f_cfg_prompt() { printf '%s' "${f_prompt:-'> '}"; }
_f_cfg_hints() { printf '%s' "${f_hints:-1}"; }
_f_cfg_marker() { printf '%s' "${f_marker:-1}"; }
_f_cfg_status() { printf '%s' "${f_status:-1}"; }
_f_visible_height() {
  local visible=$(_f_cfg_height)
  ((visible > 100)) && visible=100
  printf '%s' "$visible"
}

_f_compute_layout() {
  local border_rows=0 status_rows=0
  local visible=$(_f_visible_height)
  (($(_f_cfg_border))) && border_rows=2
  if (($(_f_cfg_status))) || (($(_f_cfg_hints))); then
    status_rows=1
  fi
  _f_ui_height=$((visible + 1 + border_rows + status_rows))
  _f_prompt_row=$_f_term_h
  _f_status_row=$((_f_term_h - 1))
  _f_start_row=$((_f_term_h - _f_ui_height + 1))
  ((_f_start_row < 1)) && _f_start_row=1
}

# Take exclusive control of /dev/tty for input and rendering.
f_init_terminal() {
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    printf 'f.sh: f_init_terminal: /dev/tty not available\n' >&2
    return 1
  fi

  # Dedicated fds so stdin/stdout remain free for caller data (e.g. $(f_select …)).
  # Use exec {var} (bash 4.1+) to auto-allocate a fd >= 10, safely above the
  # 0-9 range that bash uses internally (e.g. the script-reading fd).  This
  # prevents the crash caused by overwriting bash's script fd when p.sh (or any
  # other script) is launched from run.sh with only fds 0-2 inherited.
  local fd
  if ! { eval "exec {_F_FD_TTY_IN}</dev/tty" 2>/dev/null; }; then
    # Fallback for bash < 4.1: use explicit high-numbered fds.
    for fd in 10 11 12 13 14 198; do
      if eval "exec ${fd}</dev/tty" 2>/dev/null; then
        _F_FD_TTY_IN=$fd
        break
      fi
    done
  fi
  if [[ -z $_F_FD_TTY_IN ]]; then
    printf 'f.sh: f_init_terminal: could not open /dev/tty for reading\n' >&2
    return 1
  fi

  if ! { eval "exec {_F_FD_TTY_OUT}>/dev/tty" 2>/dev/null; }; then
    for fd in 11 12 13 14 15 199; do
      if [[ $fd -eq $_F_FD_TTY_IN ]]; then continue; fi
      if eval "exec ${fd}>/dev/tty" 2>/dev/null; then
        _F_FD_TTY_OUT=$fd
        break
      fi
    done
  fi
  if [[ -z $_F_FD_TTY_OUT ]]; then
    eval "exec ${_F_FD_TTY_IN}<&-"
    _F_FD_TTY_IN=''
    printf 'f.sh: f_init_terminal: could not open /dev/tty for writing\n' >&2
    return 1
  fi

  _f_have_tput=0
  if command -v tput >/dev/null 2>&1; then
    tput cols <&${_F_FD_TTY_IN} >/dev/null 2>&1 && _f_have_tput=1
  fi
  _f_have_sort=0
  command -v sort >/dev/null 2>&1 && _f_have_sort=1
  _f_have_awk=0
  command -v awk >/dev/null 2>&1 && _f_have_awk=1

  _f_tty_saved=$(stty -g <&${_F_FD_TTY_IN} 2>/dev/null) || _f_tty_saved=''

  # Raw mode: disable all input translation so keys arrive as-is (Enter = \r).
  _f_tty_set_raw

  # Avoid readline eating Enter/Ctrl-J when this shell is interactive.
  bind 'set bind-tty-special-chars off' 2>/dev/null || true

  _f_update_dimensions
  _f_compute_layout
  _f_init_colors

  # Save cursor position and hide it while the menu is active.
  _f_tty $'\0337'
  _f_tty_hide_cursor
  _f_tty $'\033[0m'

  _f_active=1
  _f_resized=0
  _f_cancelled=0

  return 0
}

# Erase only the UI region (preserve scrollback above it).
_f_clear_ui_region() {
  local row
  for ((row = _f_start_row; row <= _f_term_h; row++)); do
    _f_tty_goto "$row" 1
    _f_tty_clear_eol
  done
}

# Fully release the terminal back to the shell.
f_restore_terminal() {
  if ((!_f_active)); then
    return 0
  fi

  _f_active=0

  local pid
  for pid in "${_f_filter_worker_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [[ -n $_f_filter_worker_pid ]]; then
    kill "$_f_filter_worker_pid" 2>/dev/null || true
    wait "$_f_filter_worker_pid" 2>/dev/null || true
  fi
  _f_filter_worker_pid=''
  _f_filter_worker_pids=()
  _f_filter_worker_seq=0
  _f_filter_worker_file=''
  _f_filter_request_file=''
  _f_filter_pending=0
  _f_filter_ready_seq=0
  _f_filter_request_seq=0
  if [[ -n $_f_filter_tmpdir ]]; then
    rm -rf -- "$_f_filter_tmpdir" 2>/dev/null || true
    _f_filter_tmpdir=''
  fi

  _f_clear_ui_region
  _f_tty $'\033[0m'
  _f_tty $'\0338'    # restore saved cursor position
  _f_tty_show_cursor

  if [[ -n $_f_tty_saved ]]; then
    stty "$_f_tty_saved" <&${_F_FD_TTY_IN} 2>/dev/null || true
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
  # Record subshell depth so inherited EXIT traps in $() / <() children
  # do not close our tty fds (file descriptors are process-wide).
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

# ---------------------------------------------------------------------------
# Fuzzy matching
# ---------------------------------------------------------------------------

_f_cfg_fuzzy()          { printf '%s' "${f_fuzzy:-1}"; }
_f_cfg_smart_priority() { printf '%s' "${f_smart_priority:-0}"; }

# Escape literal text for use in a shell glob pattern.
_f_glob_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\*/\\*}
  s=${s//\?/\\?}
  s=${s//\[/\\[}
  printf '%s' "$s"
}

# Case-insensitive substring test (glob-safe for [, *, ?, etc.).
_f_contains_ci() {
  local hay=${1,,} needle=${2,,}
  [[ -z $needle ]] && return 0
  [[ ${hay//"$needle"/} != "$hay" ]]
}

_f_prepare_items() {
  local i n=${#_f_items[@]}
  _f_items_lower=()
  for ((i = 0; i < n; i++)); do
    _f_items_lower[i]=${_f_items[i],,}
  done
}

_f_substring_pos_lc() {
  local tlower=$1 qlower=$2 qpat prefix

  [[ -z $qlower ]] && { printf '0'; return 0; }

  [[ ${tlower//"$qlower"/} != "$tlower" ]] || return 1

  qpat=$(_f_glob_escape "$qlower")
  prefix=${tlower%%$qpat*}
  printf '%s' "${#prefix}"
}

_f_substring_score() {
  local text_lower=$1 pos
  pos=$(_f_substring_pos_lc "$text_lower" "$_f_query_lower") || return 1
  _f_last_score=$((10000 - pos))
  return 0
}

_f_fuzzy_score() {
  local text=$1 text_lower=$2
  local qlen=${#_f_query_lower}

  if ((qlen == 0)); then
    _f_last_score=0
    return 0
  fi

  local qlower=$_f_query_lower
  local tlen=${#text_lower}
  local qi=0 ti=0 score=0 prev_match=-2 consec=0

  while ((ti < tlen && qi < qlen)); do
    if [[ ${text_lower:ti:1} == "${qlower:qi:1}" ]]; then
      local bonus=0
      if ((prev_match == ti - 1)); then
        ((consec++))
        ((bonus += 2 + consec))
      else
        consec=0
      fi
      ((ti == 0)) && ((bonus += 3))
      if ((ti > 0)); then
        case ${text_lower:ti-1:1} in
          '/'|'-'|'_'|'.'|' '|$'\t') ((bonus += 4)) ;;
        esac
      fi
      if ((ti > 0)); then
        local c_prev=${text:ti-1:1} c_cur=${text:ti:1}
        [[ $c_prev =~ [a-z] && $c_cur =~ [A-Z] ]] && ((bonus += 3))
      fi
      ((score += 1 + bonus))
      prev_match=ti
      ((qi++))
    fi
    ((ti++))
  done

  if ((qi == qlen)); then
    _f_last_score=$((score * 10000 - tlen))
    return 0
  fi
  return 1
}

# Score one item: fuzzy mode uses substring hits as a strong ranking boost.
# When f_smart_priority=1 (and f_fuzzy=1) two hard tiers are used:
#   Tier 1 (10 000 000 + sub_score): items that ALSO pass the normal substring
#           search — regardless of fuzzy quality, always ranked above tier 2.
#   Tier 2 (fuzzy_score):            fuzzy-only matches, sorted by fuzzy quality.
_f_item_score() {
  local text=$1 text_lower=$2
  local sub_score=0 fuzzy_score=0 has_sub=0 has_fuzzy=0

  if _f_substring_score "$text_lower"; then
    has_sub=1
    sub_score=$_f_last_score
    if (($(_f_cfg_fuzzy))); then
      if (($(_f_cfg_smart_priority))); then
        _f_last_score=$((10000000 + sub_score))
        return 0
      fi
      _f_last_score=$((2000000 + sub_score))
      return 0
    fi
    _f_last_score=$sub_score
    return 0
  fi

  if (($(_f_cfg_fuzzy))); then
    if _f_fuzzy_score "$text" "$text_lower"; then
      has_fuzzy=1
      fuzzy_score=$_f_last_score
      if (($(_f_cfg_smart_priority))); then
        _f_last_score=$fuzzy_score
        return 0
      fi
      _f_last_score=$fuzzy_score
      return 0
    fi

    if (($(_f_cfg_smart_priority))); then
      return 1
    fi

    return 1
  fi
  return 1
}

f_filter_items() {
  _f_filtered=()

  local i n=${#_f_items[@]}
  local check_request=0 check_every=16

  if ((${#_f_query} == 0)); then
    for ((i = 0; i < n; i++)); do
      _f_filtered+=("$i")
    done
    return 0
  fi

  local -a candidates=() cand_scores=()
  if ((_f_have_awk)); then
    local -a scored_rows=() row
    mapfile -t scored_rows < <(_f_filter_items_awk_rows "$_f_query")
    for row in "${scored_rows[@]}"; do
      IFS=$'\t' read -r score idx <<<"$row"
      candidates+=("$idx")
      cand_scores+=("$score")
    done
  else
    if [[ -n $_f_filter_request_file && $_f_filter_worker_seq -gt 0 ]]; then
      check_request=1
    fi

    for ((i = 0; i < n; i++)); do
      if ((check_request && (i % check_every == 0))); then
        _f_filter_worker_is_current "$_f_filter_worker_seq" "$_f_query" || return 2
      fi
      _f_item_score "${_f_items[i]}" "${_f_items_lower[i]}" || continue
      candidates+=("$i")
      cand_scores+=("$_f_last_score")
    done
  fi

  local m=${#candidates[@]}
  if ((m == 0)); then
    return 0
  fi

  if ((check_request)); then
    _f_filter_worker_is_current "$_f_filter_worker_seq" "$_f_query" || return 2
  fi

  if ((m > 32)) && ((_f_have_sort)); then
    local -a rows=() sorted=() row score idx
    local row_index=0
    for ((i = 0; i < m; i++)); do
      printf -v row '%020d\t%d' "${cand_scores[i]}" "${candidates[i]}"
      rows+=("$row")
    done
    mapfile -t sorted < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1r)
    for row in "${sorted[@]}"; do
      IFS=$'\t' read -r score idx <<<"$row"
      if ((check_request && (row_index % check_every == 0))); then
        _f_filter_worker_is_current "$_f_filter_worker_seq" "$_f_query" || return 2
      fi
      _f_filtered+=("$idx")
      ((row_index++))
    done
    return 0
  fi

  local a b tmp_i tmp_s best
  for ((a = 0; a < m; a++)); do
    if ((check_request && (a % check_every == 0))); then
      _f_filter_worker_is_current "$_f_filter_worker_seq" "$_f_query" || return 2
    fi
    best=$a
    for ((b = a + 1; b < m; b++)); do
      ((cand_scores[b] > cand_scores[best])) && best=$b
    done
    if ((best != a)); then
      tmp_i=${candidates[a]}; candidates[a]=${candidates[best]}; candidates[best]=$tmp_i
      tmp_s=${cand_scores[a]}; cand_scores[a]=${cand_scores[best]}; cand_scores[best]=$tmp_s
    fi
    _f_filtered+=("${candidates[a]}")
  done
}

_f_filter_items_awk_rows() {
  local query=$1 fuzzy=$(_f_cfg_fuzzy) smart=$(_f_cfg_smart_priority)

  printf '%s\n' "${_f_items[@]}" | awk -v query="$query" -v fuzzy="$fuzzy" -v smart="$smart" '
    function fuzzy_score(text, query,    tl, ql, tlen, qlen, ti, qi, score, prev_match, consec, bonus, prev_ch, cur_ch) {
      tl = tolower(text)
      ql = tolower(query)
      tlen = length(tl)
      qlen = length(ql)
      if (qlen == 0) {
        return 0
      }
      qi = 1
      ti = 1
      score = 0
      prev_match = -2
      consec = 0
      while (ti <= tlen && qi <= qlen) {
        if (substr(tl, ti, 1) == substr(ql, qi, 1)) {
          bonus = 0
          if (prev_match == ti - 1) {
            consec++
            bonus += 2 + consec
          } else {
            consec = 0
          }
          if (ti == 1) {
            bonus += 3
          }
          if (ti > 1) {
            prev_ch = substr(tl, ti - 1, 1)
            if (prev_ch ~ /[\/._ \t-]/) {
              bonus += 4
            }
            prev_ch = substr(text, ti - 1, 1)
            cur_ch = substr(text, ti, 1)
            if (prev_ch ~ /[a-z]/ && cur_ch ~ /[A-Z]/) {
              bonus += 3
            }
          }
          score += 1 + bonus
          prev_match = ti
          qi++
        }
        ti++
      }
      if (qi > qlen) {
        return score * 10000 - length(text)
      }
      return -1
    }

    {
      idx = NR - 1
      if (query == "") {
        print "0\t" idx
        next
      }

      tl = tolower($0)
      ql = tolower(query)
      pos = index(tl, ql)
      has_sub = (pos > 0)
      sub_score = has_sub ? (10001 - pos) : 0

      if (fuzzy == 0) {
        if (has_sub) {
          print sub_score "\t" idx
        }
        next
      }

      if (smart == 1 && has_sub) {
        print (10000000 + sub_score) "\t" idx
        next
      }

      if (has_sub) {
        print (2000000 + sub_score) "\t" idx
        next
      }

      fuzzy_rank = fuzzy_score($0, query)
      has_fuzzy = (fuzzy_rank >= 0)

      if (smart == 1) {
        if (has_fuzzy) {
          print fuzzy_rank "\t" idx
        }
        next
      }

      if (has_fuzzy) {
        print fuzzy_rank "\t" idx
      }
    }
  '
}

_f_filter_ensure_tmpdir() {
  if [[ -n $_f_filter_tmpdir ]]; then
    return 0
  fi

  if command -v mktemp >/dev/null 2>&1; then
    _f_filter_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fsh.XXXXXX" 2>/dev/null) || _f_filter_tmpdir=''
  fi

  if [[ -z $_f_filter_tmpdir ]]; then
    _f_filter_tmpdir="${TMPDIR:-/tmp}/fsh.${BASHPID:-$$}"
    mkdir -p -- "$_f_filter_tmpdir" 2>/dev/null || return 1
  fi

  _f_filter_request_file="$_f_filter_tmpdir/request"

  return 0
}

_f_filter_write_request() {
  local seq=$1 query=$2 tmp_file

  _f_filter_ensure_tmpdir || return 1
  tmp_file="${_f_filter_request_file}.tmp.${BASHPID:-$$}"
  printf '%s\t%s\n' "$seq" "$query" >"$tmp_file" && mv -f -- "$tmp_file" "$_f_filter_request_file"
}

_f_filter_worker_is_current() {
  local seq=$1 query=$2 request_seq request_query

  [[ -f $_f_filter_request_file ]] || return 1
  IFS=$'\t' read -r request_seq request_query < "$_f_filter_request_file" 2>/dev/null || return 1
  [[ $request_seq == "$seq" && $request_query == "$query" ]]
}

_f_filter_reap_stale_workers() {
  local pid
  local -a live_pids=()

  for pid in "${_f_filter_worker_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      live_pids+=("$pid")
    else
      wait "$pid" 2>/dev/null || true
    fi
  done

  _f_filter_worker_pids=("${live_pids[@]}")
}

_f_filter_worker() {
  local seq=$1 query=$2 result_file=$3 tmp_file

  _f_filter_worker_is_current "$seq" "$query" || return 2
  _f_query=$query
  _f_query_lower=${query,,}
  f_filter_items || return $?
  _f_filter_worker_is_current "$seq" "$query" || return 2

  tmp_file="${result_file}.tmp.${BASHPID:-$$}"
  {
    local idx
    for idx in "${_f_filtered[@]}"; do
      printf '%s\n' "$idx"
    done
  } >"$tmp_file" && mv -f -- "$tmp_file" "$result_file"
}

_f_filter_start_worker() {
  local seq=$1 query=$2

  _f_filter_ensure_tmpdir || return 1

  _f_filter_worker_seq=$seq
  _f_filter_worker_file="$_f_filter_tmpdir/filter.$seq"
  _f_filter_pending=1

  _f_filter_write_request "$seq" "$query" || return 1
  _f_filter_worker "$seq" "$query" "$_f_filter_worker_file" &
  _f_filter_worker_pid=$!
}

_f_filter_sync_current() {
  _f_query_lower=${_f_query,,}
  f_filter_items
  _f_filter_ready_seq=$_f_filter_request_seq
  _f_filter_pending=0
}

_f_filter_poll_worker() {
  local pid=$_f_filter_worker_pid seq=$_f_filter_worker_seq file=$_f_filter_worker_file

  _f_filter_reap_stale_workers

  if [[ -z $pid ]]; then
    if ((_f_filter_request_seq > _f_filter_ready_seq)) && ((${#_f_query} > 0)) && ((${#_f_items[@]} > _f_filter_async_threshold)); then
      _f_filter_start_worker "$_f_filter_request_seq" "$_f_query" || {
        _f_filter_sync_current
        return 0
      }
    fi
    return 1
  fi

  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  wait "$pid" 2>/dev/null || true
  _f_filter_worker_pid=''

  if [[ -f $file ]]; then
    if ((seq == _f_filter_request_seq)); then
      mapfile -t _f_filtered < "$file"
      _f_filter_ready_seq=$seq
      _f_filter_pending=0
    fi
    rm -f -- "$file" 2>/dev/null || true
  fi

  _f_filter_worker_seq=0
  _f_filter_worker_file=''

  if ((_f_filter_request_seq > _f_filter_ready_seq)) && ((${#_f_query} > 0)) && ((${#_f_items[@]} > _f_filter_async_threshold)); then
    _f_filter_start_worker "$_f_filter_request_seq" "$_f_query" || {
      _f_filter_sync_current
      return 0
    }
  fi

  return 0
}

_f_filter_request() {
  local query=$1

  _f_filter_request_seq=$((_f_filter_request_seq + 1))
  _f_query=$query
  _f_query_lower=${query,,}
  _f_cursor=0
  _f_scroll=0

  if [[ -n $_f_filter_worker_pid ]]; then
    kill "$_f_filter_worker_pid" 2>/dev/null || true
    _f_filter_worker_pids+=("$_f_filter_worker_pid")
    _f_filter_worker_pid=''
    _f_filter_worker_seq=0
    _f_filter_worker_file=''
  fi

  _f_filter_write_request "$_f_filter_request_seq" "$query" || true

  if ((${#query} == 0)) || ((${#_f_items[@]} <= _f_filter_async_threshold)); then
    _f_filter_sync_current
    return 0
  fi

  _f_filter_start_worker "$_f_filter_request_seq" "$query" || {
    _f_filter_sync_current
    return 0
  }
}

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

_f_truncate() {
  local s=$1 max=$2
  if ((${#s} <= max)); then
    _f_last_string=$s
  elif ((max <= 1)); then
    _f_last_string=${s:0:max}
  else
    _f_last_string="${s:0:max-1}…"
  fi
}

_f_highlight_substring() {
  local query=$1 text=$2
  local qlen=${#query} start end text_lower=${text,,} query_lower=${query,,}
  local c_match=${f_color_match:-$'\033[1;33m'}
  local c_reset=${f_reset:-$'\033[0m'}
  local c_normal=${f_color_normal:-$'\033[0m'}

  if ((qlen == 0)) || ! _f_contains_ci "$text" "$query"; then
    _f_last_string=$text
    return
  fi

  start=$(_f_substring_pos_lc "$text_lower" "$query_lower")
  end=$((start + qlen))
  _f_last_string="${text:0:start}${c_match}${text:start:qlen}${c_reset}${c_normal}${text:end}${c_reset}"
}

_f_highlight_matches() {
  local query=$1 text=$2
  local qlen=${#query}

  if ((qlen == 0)) || [[ -z ${f_color_match:-} ]]; then
    _f_last_string=$text
    return
  fi

  if ((!$(_f_cfg_fuzzy))) || _f_contains_ci "$text" "$query"; then
    _f_highlight_substring "$query" "$text"
    return
  fi

  local qlower=${query,,} tlower=${text,,}
  local tlen=${#text} qi=0 ti=0 out='' in_match=0 ch
  local c_match=${f_color_match:-$'\033[1m'}
  local c_reset=${f_reset:-$'\033[0m'}
  local c_normal=${f_color_normal:-$'\033[0m'}

  while ((ti < tlen)); do
    ch=${text:ti:1}
    if ((qi < qlen)) && [[ ${tlower:ti:1} == "${qlower:qi:1}" ]]; then
      if ((!in_match)); then
        out+="$c_match"
        in_match=1
      fi
      out+="$ch"
      ((qi++))
    else
      if ((in_match)); then
        out+="${c_reset}${c_normal}"
        in_match=0
      fi
      out+="$ch"
    fi
    ((ti++))
  done
  ((in_match)) && out+="${c_reset}${c_normal}"
  _f_last_string=$out
}

_f_sync_scroll() {
  local total=${#_f_filtered[@]}
  local visible=$(_f_visible_height)

  if ((total == 0)); then
    _f_cursor=0
    _f_scroll=0
    return
  fi

  ((_f_cursor >= total)) && _f_cursor=$((total - 1))
  ((_f_cursor < 0)) && _f_cursor=0

  if ((_f_cursor < _f_scroll)); then
    _f_scroll=$_f_cursor
  elif ((_f_cursor >= _f_scroll + visible)); then
    _f_scroll=$((_f_cursor - visible + 1))
  fi

  local max_scroll=$((total - visible))
  ((max_scroll < 0)) && max_scroll=0
  ((_f_scroll > max_scroll)) && _f_scroll=$max_scroll
  ((_f_scroll < 0)) && _f_scroll=0
}

# Position the text cursor at the end of the prompt on the bottom line.
f_move_to_bottom() {
  local prompt
  prompt=$(_f_cfg_prompt)
  local col=$((${#prompt} + ${#_f_query} + 2))
  _f_tty_goto "$_f_prompt_row" "$col"
}

f_render_results() {
  local row=$_f_start_row
  local width=$_f_term_w
  local inner_width=$width
  local total=${#_f_filtered[@]}
  local visible=$(_f_visible_height)
  local r idx item_idx item plain rendered line prefix border marker
  local marker_w=0 scroll_up=0 scroll_down=0
  local c_border=${f_color_border:-$'\033[90m'}
  local c_reset=${f_reset:-$'\033[0m'}

  _f_sync_scroll

  border=$(_f_cfg_border)
  marker=$(_f_cfg_marker)
  ((marker)) && marker_w=2
  ((total > visible && _f_scroll > 0)) && scroll_up=1
  ((total > visible && _f_scroll + visible < total)) && scroll_down=1

  if ((border)); then
    _f_tty_goto "$row" 1
    if ((scroll_up)); then
      _f_tty '%s┌─▲' "$c_border"
      local j
      for ((j = 0; j < width - 4; j++)); do _f_tty '─'; done
      _f_tty '┐%s' "$c_reset"
    else
      _f_tty '%s┌' "$c_border"
      local j
      for ((j = 0; j < width - 2; j++)); do _f_tty '─'; done
      _f_tty '┐%s' "$c_reset"
    fi
    _f_tty_clear_eol
    ((row++))
    inner_width=$((width - 4))
  fi
  ((inner_width < 4)) && inner_width=4
  inner_width=$((inner_width - marker_w))

  for ((r = 0; r < visible; r++)); do
    _f_tty_goto "$row" 1
    line=''
    prefix=''

    if ((border)); then
      prefix="${c_border}│${c_reset} "
    fi

    idx=$((_f_scroll + r))
    if ((idx < total)); then
      item_idx=${_f_filtered[idx]}
      item=${_f_items[item_idx]}
      _f_truncate "$item" "$inner_width"
      plain=$_f_last_string
      _f_highlight_matches "$_f_query" "$plain"
      rendered=$_f_last_string

      if ((marker)); then
        if ((idx == _f_cursor)); then
          prefix+="${f_color_match:-$'\033[1;33m'}▸ ${c_reset}"
        else
          prefix+='  '
        fi
      fi

      if ((idx == _f_cursor)); then
        line="${prefix}${f_color_selected:-$'\033[46;30;1m'}${rendered}${c_reset}"
      else
        line="${prefix}${f_color_normal:-$'\033[0m'}${rendered}${c_reset}"
      fi
    elif ((border)); then
      line="${prefix}"
    fi

    _f_tty '%s' "$line"
    _f_tty_clear_eol
    ((row++))
  done

  if ((border)); then
    _f_tty_goto "$row" 1
    if ((scroll_down)); then
      _f_tty '%s└─▼' "$c_border"
      local j
      for ((j = 0; j < width - 4; j++)); do _f_tty '─'; done
      _f_tty '┘%s' "$c_reset"
    else
      _f_tty '%s└' "$c_border"
      local j
      for ((j = 0; j < width - 2; j++)); do _f_tty '─'; done
      _f_tty '┘%s' "$c_reset"
    fi
    _f_tty_clear_eol
  fi
}

f_render_status() {
  local total=${#_f_filtered[@]} visible=$(_f_visible_height) text='' hints=''
  local c_dim=${f_color_dim:-$'\033[2m'}
  local c_reset=${f_reset:-$'\033[0m'}

  if (($(_f_cfg_status))); then
    if ((_f_filter_pending)); then
      text='searching…'
    elif ((${#_f_query} > 0)); then
      if ((total == 0)); then
        text='no matches'
      else
        text="$(( _f_cursor + 1 ))/$total"
      fi
    else
      text="$total item$([[ $total -eq 1 ]] || echo s)"
    fi
    if ((total > visible)); then
      local above=$_f_scroll below=$((total - _f_scroll - visible))
      ((above > 0)) && text+=" · ▲$above"
      ((below > 0)) && text+=" · ▼$below"
    fi
  fi

  if (($(_f_cfg_hints))); then
    hints='↑↓ move · enter select · esc cancel'
    [[ -n $text ]] && hints="  ·  $hints"
  fi

  [[ -z $text$hints ]] && return 0

  _f_tty_goto "$_f_status_row" 1
  _f_tty '%s%s%s%s' "$c_dim" "$text" "$hints" "$c_reset"
  _f_tty_clear_eol
}

f_render_prompt() {
  local prompt
  prompt=$(_f_cfg_prompt)
  local c_prompt=${f_color_prompt:-$'\033[1;35m'}
  local c_query=${f_color_query:-$'\033[1;37m'}
  local c_reset=${f_reset:-$'\033[0m'}
  _f_tty_goto "$_f_prompt_row" 1
  _f_tty '%s%s%s %s%s█%s' \
    "$c_prompt" "$prompt" "$c_reset" \
    "$c_query" "$_f_query" "$c_reset"
  _f_tty_clear_eol
}

f_render_prompt_status() {
  _f_update_dimensions
  _f_compute_layout
  _f_tty_hide_cursor
  f_render_status
  f_render_prompt
  f_move_to_bottom
}

f_render() {
  _f_update_dimensions
  _f_compute_layout
  _f_clear_ui_region
  _f_tty_hide_cursor
  f_render_results
  f_render_status
  f_render_prompt
  f_move_to_bottom
}

# ---------------------------------------------------------------------------
# Keyboard input (reads /dev/tty only; sets _f_last_key, never writes stdout)
# ---------------------------------------------------------------------------

# Blocking raw mode — one byte per read, no CR/NL translation, no signals from keys.
_f_tty_set_raw() {
  stty -echo -icanon -isig -ixon -ixoff \
       -inlcr -igncr -icrnl -iexten \
       min 1 time 0 <&${_F_FD_TTY_IN} 2>/dev/null \
    || stty -echo -icanon -isig min 1 time 0 <&${_F_FD_TTY_IN} 2>/dev/null \
    || true
}

# Timed poll mode — used only while finishing an escape sequence.
_f_tty_set_poll() {
  stty -echo -icanon -isig -ixon -ixoff \
       -inlcr -igncr -icrnl -iexten \
       min 0 time 1 <&${_F_FD_TTY_IN} 2>/dev/null \
    || stty -echo -icanon min 0 time 0 <&${_F_FD_TTY_IN} 2>/dev/null \
    || true
}

_f_key_is_enter() {
  local byte=$1
  [[ -n $byte ]] || return 1
  local ord
  ord=$(printf '%d' "'$byte")
  ((ord == 13 || ord == 10))
}

# Read exactly one raw byte from the tty (-N 1, not -n 1: Enter/\n must not be eaten).
_f_read_byte() {
  local _var=$1 _timeout=${2:-}
  if ((!_f_active)) || [[ -z $_F_FD_TTY_IN ]]; then
    return 1
  fi
  if [[ -n $_timeout ]]; then
    IFS= read -rsN1 -t "$_timeout" -u "$_F_FD_TTY_IN" "$_var" 2>/dev/null
  else
    IFS= read -rsN1 -u "$_F_FD_TTY_IN" "$_var" 2>/dev/null
  fi
}

# Briefly allow timed reads while parsing escape sequences.
_f_tty_escape_mode() {
  _f_tty_set_poll
}

_f_tty_raw_mode() {
  _f_tty_set_raw
}

f_read_key() {
  local _timeout=${1:-}
  _f_last_key=''
  local k k1 k2 k3 rest

  # Always read in blocking raw mode so Enter (\r) is not dropped or split.
  _f_tty_set_raw
  if [[ -n $_timeout ]]; then
    _f_read_byte k "$_timeout" || return 1
  else
    _f_read_byte k || return 1
  fi

  # Detect Enter by byte value (terminals may send \r, \n, or CRLF).
  if _f_key_is_enter "$k"; then
    _f_tty_set_poll
    _f_read_byte rest 0.02 || rest=''
    if _f_key_is_enter "$rest"; then
      rest=''
    fi
    _f_tty_set_raw
    _f_last_key='enter'
    return 0
  fi

  case "$k" in
    $'\x03') _f_last_key='ctrl-c'; return 0 ;;
    $'\x04') _f_last_key='ctrl-d'; return 0 ;;
    $'\x1c') _f_last_key='ctrl-\\'; return 0 ;;
    $'\x7f'|$'\b') _f_last_key='backspace'; return 0 ;;
    $'\x1b')
      _f_tty_escape_mode
      _f_read_byte k1 0.05 || k1=''
      if [[ -n $k1 ]]; then
        case "$k1" in
          '[')
            _f_read_byte k2 0.05 || k2=''
            case "$k2" in
              A) _f_tty_raw_mode; _f_last_key='up'; return 0 ;;
              B) _f_tty_raw_mode; _f_last_key='down'; return 0 ;;
              C) _f_tty_raw_mode; _f_last_key='right'; return 0 ;;
              D) _f_tty_raw_mode; _f_last_key='left'; return 0 ;;
              3)
                _f_read_byte k3 0.05 || k3=''
                if [[ $k3 == '~' ]]; then
                  _f_tty_raw_mode
                  _f_last_key='delete'
                  return 0
                fi
                ;;
            esac
            ;;
          O)
            _f_read_byte k2 0.05 || k2=''
            case "$k2" in
              A) _f_tty_raw_mode; _f_last_key='up'; return 0 ;;
              B) _f_tty_raw_mode; _f_last_key='down'; return 0 ;;
              C) _f_tty_raw_mode; _f_last_key='right'; return 0 ;;
              D) _f_tty_raw_mode; _f_last_key='left'; return 0 ;;
            esac
            ;;
        esac
        while _f_read_byte rest 0.01 && [[ -n $rest ]]; do
          [[ $rest == '~' || $rest == 'u' ]] && break
        done
      fi
      _f_tty_raw_mode
      _f_last_key='esc'
      return 0
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
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# f_select item [item...]
# Pass items as args, or pre-fill _f_items[] and call with no args (large lists).
# Prints the chosen item to stdout.  Returns 1 on cancel.
f_select() {
  if (("$#" > 0)); then
    _f_items=("$@")
  elif ((${#_f_items[@]} == 0)); then
    printf 'f.sh: f_select: no items provided\n' >&2
    return 1
  fi
  _f_prepare_items
  _f_query=''
  _f_query_lower=''
  _f_cursor=0
  _f_scroll=0
  _f_cancelled=0
  _f_filter_request_seq=0
  _f_filter_ready_seq=0
  _f_filter_worker_seq=0
  _f_filter_worker_pid=''
  _f_filter_worker_file=''
  _f_filter_pending=0

  f_init_terminal || return 1
  _f_setup_traps

  local selected='' key keychar

  _f_filter_request ''
  f_render

  while true; do
    if ((_f_resized)); then
      _f_resized=0
      f_render
    fi

    if _f_filter_poll_worker; then
      f_render
    fi

    # Signal handler already restored the terminal.
    if ((_f_cancelled)); then
      return 1
    fi

    if ! f_read_key 0.05; then
      continue
    fi
    key=$_f_last_key
    local needs_render=0

    case "$key" in
      up)
        ((_f_cursor > 0)) && ((_f_cursor--))
        needs_render=1
        ;;
      down)
        if ((${#_f_filtered[@]} > 0)); then
          ((_f_cursor < ${#_f_filtered[@]} - 1)) && ((_f_cursor++))
        fi
        needs_render=1
        ;;
      backspace|delete)
        if ((${#_f_query} > 0)); then
          _f_query=${_f_query:0:${#_f_query}-1}
          _f_cursor=0
          _f_scroll=0
          _f_filter_request "$_f_query"
        fi
        if ((_f_filter_pending)); then
          f_render_prompt_status
        else
          needs_render=1
        fi
        ;;
      char:*)
        keychar=${key#char:}
        _f_query+="$keychar"
        _f_cursor=0
        _f_scroll=0
        _f_filter_request "$_f_query"
        if ((_f_filter_pending)); then
          f_render_prompt_status
        else
          needs_render=1
        fi
        ;;
      enter)
        if ((_f_filter_pending)); then
          continue
        fi
        if ((${#_f_filtered[@]} > 0)); then
          local pick=${_f_filtered[_f_cursor]}
          selected=${_f_items[pick]}
          _f_clear_traps
          f_restore_terminal
          printf '%s\n' "$selected"
          return 0
        elif ((${#_f_query} == 0)); then
          _f_clear_traps
          f_restore_terminal
          return 1
        else
          f_render
          continue
        fi
        ;;
      ctrl-c|ctrl-\\)
        _f_clear_traps
        f_restore_terminal
        return 1
        ;;
      esc|ctrl-d)
        _f_clear_traps
        f_restore_terminal
        return 1
        ;;
      *)
        continue
        ;;
    esac

    ((needs_render)) && f_render
  done
}

# ---------------------------------------------------------------------------
# Demo (run directly: bash f.sh)
# ---------------------------------------------------------------------------
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  fruits=(
    'Apple' 'Apricot' 'Banana' 'Blackberry' 'Blueberry' 'Cherry'
    'Cranberry' 'Date' 'Fig' 'Grape' 'Grapefruit' 'Kiwi' 'Lemon'
    'Lime' 'Mango' 'Melon' 'Nectarine' 'Orange' 'Papaya' 'Peach'
    'Pear' 'Pineapple' 'Plum' 'Pomegranate' 'Raspberry' 'Strawberry'
    'Watermelon'
  )

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
