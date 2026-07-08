# fsh

**fsh** is a set of interactive terminal scripts built on f.sh, a pure-bash fuzzy menu library.

**dependencies:**

- bash 4+ (or any other bash-based terminal like zsh)
- a controlling terminal (/dev/tty)
- `awk` for fast search filtering
- extra tools each script wraps (ex. grim, slurp, bluetoothctl)

---

## quick start

```bash
git clone https://github.com/arozoid/fsh.git
cd fsh
./run.sh
```

run any script directly:

```bash
./wifi.sh
./p.sh
./s.sh
```

---

## install

```bash
./manage_f.sh                    # interactive menu
./manage_f.sh install local      # ~/fsh + ~/bin/fsh + fsh alias
./manage_f.sh install global     # /fsh + /bin/fsh
./manage_f.sh uninstall both       # remove local and global
```

after local install:

```bash
fsh                              # alias in .bashrc / .zshrc
export PATH="$HOME/bin:$PATH"      # if needed
```

after global install:

```bash
fsh                              # from anywhere
```

reinstall to sync an existing copy:

```bash
./manage_f.sh install global
```

---

## launcher

`run.sh` (or `fsh`) lists every top-level `*.sh` script from these paths — first match wins, no duplicates:

1. `~/Downloads/fsh`
2. `~/Documents/fsh`
3. `~/Documents/@project/fsh`
4. `~/fsh`
5. `/fsh`
6. the directory containing `run.sh`

---

## scripts

* **run.sh:** launcher menu
* **manage_f.sh:** install / uninstall fsh
* **wifi.sh:** wifi manager (`nmcli` or `wpa_cli`)
* **p.sh:** search processes, kill, inspect, copy pid
* **app.sh:** launch desktop apps from `.desktop` files
* **s.sh:** pick ssh hosts from config
* **bt.sh:** bluetooth picker (`bluetoothctl`)
* **ss.sh:** screenshots (`grim` + `slurp`)
* **power.sh:** lock, suspend, logout, reboot, shutdown
* **hist.sh:** fuzzy-pick shell history
* **pkg.sh:** package helper (`apk`, `apt`, `dnf`, `pacman`)

---

## f.sh api

source the library:

```bash
source lib/common.sh
fsh_menu_defaults
f_prompt='pick: '
f_height=12
f_border=1
choice=$(f_select "${items[@]}") || exit 1
```

main entry point — `f_select item [item...]` prints the selection to stdout, returns 1 on cancel.

config vars (set before `f_select`):

| variable | default | description |
|----------|---------|-------------|
| `f_prompt` | `'> '` | prompt string shown at the bottom |
| `f_height` | `10` | number of visible list rows |
| `f_border` | `0` | `1` to draw a box around the list |
| `f_fuzzy` | `1` | `1` hybrid fuzzy+substring, `0` substring-only (exact match filter) |
| `f_smart_priority` | `0` | `1` to guarantee normal (substring) hits always rank above fuzzy-only hits — see below |
| `f_hints` | `1` | `0` hides the key-hint line |
| `f_marker` | `1` | `0` hides the `▸` cursor marker |
| `f_status` | `1` | `0` hides the match count / scroll info |
| `f_min_query_length` | `0` | minimum characters before filtering starts (see below) |
| `f_search_delay` | `100` | milliseconds to wait after last keystroke before searching — debounces fast typing |
| `f_color_*`, `f_reset` | ansi escapes | colors for each ui element |

### `f_fuzzy` modes

| value | behaviour |
|-------|-----------|
| `1` (default) | fuzzy matching — items matching any subsequence of the query are included; substring hits are ranked higher |
| `0` | substring-only — only items that contain the exact query string (case-insensitive) are shown |

### `f_smart_priority` (requires `f_fuzzy=1`)

When set to `1`, scoring switches to a strict two-tier model:

* **Tier 1** — items that also pass the normal substring search are scored `10 000 000 + sub_score` (early match position → higher score within tier).
* **Tier 2** — fuzzy-only matches keep their raw fuzzy score.

Tier-1 items always appear above tier-2 items regardless of how high a fuzzy score might be, making the list feel more "expected" when the query has obvious substring matches scattered among many fuzzy hits.

```bash
fsh_menu_defaults
f_fuzzy=1
f_smart_priority=1
choice=$(f_select "${items[@]}") || exit 1
```

`fsh_menu_defaults` resets `f_smart_priority` to `0` on every call, so enabling it for one menu never bleeds into the next.

### `f_min_query_length`

when set to `2` or higher, the menu stays empty until the query reaches that many characters. no data is loaded from file or dynamic providers until the threshold is met. useful for very large lists where showing everything upfront is wasteful.

the status bar shows a live counter — `type at least 2 chars (1/2)` — so the user knows how much more to type.

```bash
fsh_menu_defaults
f_min_query_length=2
choice=$(f_select_file symbols.txt) || exit 1
```

### `f_search_delay`

search is delayed `f_search_delay` milliseconds after the last keystroke, so fast typing doesn't fire a new search on every character. when the user pauses, only the final query is sent.

the timer resets on every keystroke (including backspace). old async searches are cancelled when a new one starts — only the latest query runs.

a value of `0` removes the delay entirely (search fires on the next poll cycle, ~30ms).

### fd allocation

`f_init_terminal` uses `exec {var}</dev/tty` (bash 4.1+ auto-allocation, picks fd ≥ 10) with a fallback to explicit fds 10–14. This avoids conflicts with bash's internal script-reading fd, which lives in the 0–9 range — particularly important when a script is launched as a subprocess with only fds 0–2 inherited.

keys: `↑` `↓` to move, type to filter, enter to select, esc to cancel.

When a search is still loading on larger lists, the prompt stays live so you can keep typing; the status line shows `searching…` until the latest results are ready.

demo:

```bash
bash lib/f.sh
```

### alternate data sources

entry points for large lists that stay off the shell heap or stream results from a provider:

- `f_select_file FILE` — read candidates directly from `FILE` during filtering (never mapfile the whole file). usage:

```bash
fsh_menu_defaults
f_prompt='unicode: '
f_fuzzy=0
choice=$(f_select_file symbols.txt) || exit 1
```

- `f_select_dynamic CALLBACK` — call `CALLBACK` with the current query; the callback should print matching lines to stdout. this is useful for paged or external providers that can limit results themselves. usage:

```bash
my_provider() {
	local query=$1

	awk -v q="${query,,}" '
		BEGIN { q=tolower(q) }
		index(tolower($0), q) { print; if (++n == 500) exit }
	' symbols.txt
}

choice=$(f_select_dynamic my_provider) || exit 1
```

these add-ons keep the renderer independent of where items originate and avoid copying large files into bash arrays.
