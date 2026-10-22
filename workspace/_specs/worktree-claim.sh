#!/usr/bin/env bash
# Worktree slot claiming for concurrent Langflow PR-validation sessions.
#
#   source ~/Langflow/pr-validation/_specs/worktree-claim.sh
#   wt_status                     # who holds what -- ticket/since/heartbeat even for stale claims
#   wt_pool                       # one key=value line per pool slot (what the agent shows Alice)
#   wt_claim LE-2189 14534        # claim a free slot -> exports SLOT, WT, PORT
#   wt_mine                       # in EVERY later shell: re-exports SLOT/WT/PORT, re-arms the keeper
#   wt_free                       # scrub your slot back to a clean, warm state and release it
#   wt_release                    # release only (stops its keeper) -- leaves the state behind
#
# THE POOL (Alice, 2026-10-16). Five permanent, warm worktrees: active, active2, active3, active4,
# active5. They are never removed. A slot is scrubbed and released (wt_free, called by qa_cleanup
# at sign-off), so the next session finds it clean with its deps (.venv, node_modules, frontend
# build) already in place. All five busy -> wt_up stops with exit 3 and the agent asks Alice which
# slot to free (wt_up --take <slot>) or whether to build a dedicated worktree (wt_up --dedicated).
#
# Two signals decide whether a slot is busy:
#   1. CLAIM FILE (authoritative) -- written at session start, lives in .claims/ OUTSIDE the
#      worktrees so it never shows up in `git status`. Covers the long stretches where a session
#      holds a slot with nothing running: analyzing a diff, building, waiting on Alice.
#   2. LIVE PROCESS (backup) -- catches a session that never claimed. Racy on its own: a session
#      between server restarts looks idle for a few seconds. Never rely on it alone.
#
# Who keeps a claim alive. The first version wrote `pid=$$` and reaped any claim whose pid was
# gone. In Claude Code every Bash call is a fresh `zsh -c`, so that pid died seconds after
# wt_claim returned -- and the next session's wt_claim deleted the claim of a session that was very
# much alive (2026-10-07: `active` lost its claim mid-validation, `active2` showed "stale" for a
# live LE-2912 session). So now:
#   - `pid=` is a detached KEEPER (setsid'd `sh` loop, survives the shell and Ctrl-C of the call).
#     Every WT_HEARTBEAT_SECS it touches the claim file -- the file's mtime IS the heartbeat. It
#     exits when the claim no longer names it (released / taken over), when the owning Claude Code
#     process ($CLAUDE_PID) exits, or after WT_CLAIM_TTL_HOURS.
#   - `session=` / `host_session=` (Claude Code session ids) let the SAME session find and re-arm
#     its claim from any later shell (wt_mine), and stop other sessions releasing it by accident.
#   - State of a claim, by keeper and heartbeat age:
#       LIVE     keeper running                         busy -- never taken, not even with --force
#       STALE    keeper gone, heartbeat < STALE_HOURS   busy -- wt_claim REFUSES it unless --force
#       EXPIRED  keeper gone, heartbeat >= STALE_HOURS  free -- wt_claim reaps it
#     Age counts from the last heartbeat, not from since=: a 20h-old claim whose session died five
#     minutes ago is still protected. Only wt_claim/wt_release ever delete a claim; wt_busy and
#     wt_status are read-only (the old wt_busy reaped as a side effect, even for a running slot).

WT_BASE="${WT_BASE:-$HOME/Langflow/pr-validation/worktrees}"
CLAIMS="$WT_BASE/.claims"
# Ports: active/active2 keep 7862/7864; the three added on 2026-10-16 use 7830/7832/7834 -- a range
# nothing else on this Mac uses (dedicated/RC reservations live in 7840-7858, EE in 7866-7898).
WT_SLOTS=${WT_SLOTS:-"active:7862 active2:7864 active3:7830 active4:7832 active5:7834"}
WT_CFG_BASE="${WT_CFG_BASE:-$HOME/Langflow/Temp}"          # per-slot config dir: $WT_CFG_BASE/langflow-config-<slot>
WT_PV="${WT_PV:-$HOME/Langflow/pr-validation}"             # files/, runs/ (read by wt_pool)
WT_SPECS="${WT_SPECS:-$HOME/Langflow/pr-validation/_specs}" # where ee-worktree.sh lives

# Machine-wide guards (Alice, 2026-10-16 -- M1, 8 cores, 16 GB, already deep in swap):
#  - ONE heavy build at a time across OSS and EE (run_clic, EE bring-up, wt_warm, ee_warm queue on
#    QA_BUILD_LOCK; the log shows "[queue] waiting ..." meanwhile);
#  - at most QA_MAX_INSTANCES QA Langflow servers listening (OSS + EE + RC, ports QA_PORT_LO-HI;
#    the nightly container on 7810 does not count). Over it, wt_up / ee_up exit 4 and the agent asks
#    Alice which instance to pause (qa_pause <port>).
QA_BUILD_LOCK="${QA_BUILD_LOCK:-$HOME/Langflow/pr-validation/worktrees/.build-lock}"
QA_MAX_INSTANCES=${QA_MAX_INSTANCES:-4}
QA_PORT_LO=${QA_PORT_LO:-7820}
QA_PORT_HI=${QA_PORT_HI:-7898}
# The EE pool (ee-worktree.sh) -- declared here too so qa_instances / qa_pause / qa_cleanup know it.
EE_WT_BASE="${EE_WT_BASE:-$HOME/Langflow/Local-instances/main/ee-worktrees}"
EE_SLOTS=${EE_SLOTS:-"ee1:7820 ee2:7822 ee3:7824 ee4:7826 ee5:7828"}

# The build lock, as POSIX-sh functions: embedded verbatim in the detached launch scripts (OSS
# run_clic, EE bring-up) and eval'ed below for the in-shell callers (wt_warm, ee_warm). The owner
# file holds the holder's pid: a holder that died (killed by wt_free/wt_down, crashed) is broken
# by the next waiter, so the queue never wedges.
_QA_BUILD_FNS='
qa_build_acquire() {
  _qbl="$QA_BUILD_LOCK"; _qbw=0
  mkdir -p "$(dirname "$_qbl")"
  until mkdir "$_qbl" 2>/dev/null; do
    _qbo=$(cat "$_qbl/owner" 2>/dev/null); _qbp=${_qbo%% *}
    if [ -n "$_qbp" ] && ! kill -0 "$_qbp" 2>/dev/null; then rm -rf "$_qbl"; continue; fi
    if [ -z "$_qbo" ] && [ -n "$(find "$_qbl" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then rm -rf "$_qbl"; continue; fi
    [ $((_qbw % 60)) -eq 0 ] && echo "[queue] waiting for the build lock -- held by: ${_qbo#* }"
    sleep 5; _qbw=$((_qbw + 5))
  done
  echo "$$ $1 (since $(date +%H:%M:%S))" > "$_qbl/owner"
  [ "$_qbw" -gt 0 ] && echo "[queue] build lock taken after ${_qbw}s"
  return 0
}
qa_build_release() {
  [ "$(cut -d" " -f1 "$QA_BUILD_LOCK/owner" 2>/dev/null)" = "$$" ] && rm -rf "$QA_BUILD_LOCK"
  return 0
}
'
eval "$_QA_BUILD_FNS"
WT_CLAIM_TTL_HOURS=${WT_CLAIM_TTL_HOURS:-24}  # keeper lifetime; wt_mine re-arms past half of it
WT_STALE_HOURS=${WT_STALE_HOURS:-12}          # dead-keeper claims younger than this are refused
WT_HEARTBEAT_SECS=${WT_HEARTBEAT_SECS:-60}
# WT_CLAIM_TTL_SECS / WT_STALE_SECS override the *_HOURS knobs (tests).

# NOTE: every loop below iterates `$(echo "$WT_SLOTS")`, not `$WT_SLOTS`. zsh (the shell these
# sessions run in) does NOT word-split unquoted parameter expansions the way bash does -- a bare
# `for pair in $WT_SLOTS` iterates ONCE over the whole string and silently reports one slot with
# the wrong port. Command substitution IS split in both shells, so `$(echo ...)` is the portable form.
# Also: never name a local `path` or `status` -- both are special in zsh.

wt_slot_port() {
  local slot="$1" pair
  for pair in $(echo "$WT_SLOTS"); do
    [ "${pair%%:*}" = "$slot" ] && { echo "${pair##*:}"; return 0; }
  done
  [ -f "$WT_BASE/.own/$slot" ] && { _wt_get "$WT_BASE/.own/$slot" port; return 0; }
  return 1
}

_wt_ttl_secs()   { echo "${WT_CLAIM_TTL_SECS:-$(( WT_CLAIM_TTL_HOURS * 3600 ))}"; }
_wt_stale_secs() { echo "${WT_STALE_SECS:-$(( WT_STALE_HOURS * 3600 ))}"; }
_wt_now()        { date +%s; }
_wt_get()        { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null; }
_wt_mtime() {
  case "$(uname)" in Darwin) stat -f %m "$1" 2>/dev/null ;; *) stat -c %Y "$1" 2>/dev/null ;; esac
}
_wt_dur() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  elif [ "$s" -ge 60 ]; then printf '%dm' $((s / 60))
  else printf '%ds' "$s"; fi
}

# The keeper. Sleeps first so wt_claim has written `pid=<keeper>` before the first check. Kept on
# one line so `ps`/`pgrep` show it whole; its argv names .claims/<slot>, which the live-process
# pattern below deliberately does not match.
_WT_KEEPER='cd / || exit 0; c=$1; o=$2; d=$3; b=$4; while sleep "$b"; do [ "$(date +%s)" -lt "$d" ] || exit 0; if [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null; then exit 0; fi; command grep -qx "pid=$$" "$c" 2>/dev/null || exit 0; touch "$c"; done'

# _wt_spawn_keeper <claim-file> <deadline-epoch> -> prints the keeper pid
_wt_spawn_keeper() {
  local f="$1" deadline="$2" owner="${CLAUDE_PID:-}"
  [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null && owner=""
  # setsid: own session + process group, so neither the end of the Bash call nor an interrupt
  # that kills the call's process group takes the keeper down. </dev/null >/dev/null: the call
  # (and this $(...)) would otherwise wait on the keeper's inherited stdout for 24 hours.
  if command -v perl >/dev/null 2>&1; then
    ( perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' \
        sh -c "$_WT_KEEPER" wt-keeper "$f" "$owner" "$deadline" "$WT_HEARTBEAT_SECS" \
        </dev/null >/dev/null 2>&1 & echo $! )
  else
    ( nohup sh -c "$_WT_KEEPER" wt-keeper "$f" "$owner" "$deadline" "$WT_HEARTBEAT_SECS" \
        </dev/null >/dev/null 2>&1 & echo $! )
  fi
}

# 0 if the claim's pid is its live keeper. A pre-keeper claim (no v=) counts as live while its pid
# runs (old `pid=$$` claims, or a hand-made `nohup sleep` holder); a v=2 pid must also still BE a
# wt-keeper, so a recycled pid does not keep a dead claim alive.
_wt_keeper_alive() {
  local f="$1" kp
  kp=$(_wt_get "$f" pid)
  [ -n "$kp" ] && kill -0 "$kp" 2>/dev/null || return 1
  [ -z "$(_wt_get "$f" v)" ] && return 0
  ps -o command= -p "$kp" 2>/dev/null | command grep -q 'wt-keeper'
}

# _wt_claim_state <slot> -> none | live | stale | expired. Read-only.
_wt_claim_state() {
  local f="$CLAIMS/$1" hb
  [ -f "$f" ] || { echo none; return; }
  _wt_keeper_alive "$f" && { echo live; return; }
  hb=$(_wt_mtime "$f"); [ -n "$hb" ] || hb=0
  if [ $(( $(_wt_now) - hb )) -lt "$(_wt_stale_secs)" ]; then echo stale; else echo expired; fi
}

# _wt_procs <slot> -> pids of processes running from that worktree. No trailing slash: a session
# whose command says `WT=.../worktrees/active;` must count too (the old `worktrees/active/` pattern
# missed it). The boundary class keeps `active` from matching `active2`. -i: git may have
# registered the path with different casing (PR-validation vs pr-validation) and pgrep matches the
# literal command line. The caller's own process group is skipped -- otherwise a Bash call that
# merely mentions the worktree path reports its own shell as "running".
_wt_procs() {
  local slot="$1" mypg p pg out="" port
  mypg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  for p in $(pgrep -fi "$(basename "$WT_BASE")/${slot}([^A-Za-z0-9_-]|\$)" 2>/dev/null); do
    pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$pg" ] && [ "$pg" = "$mypg" ] && continue
    out="$out$p "
  done
  # A server launched with relative paths (`uv run langflow run`, `make run_clic`) never names the
  # worktree on its command line; whatever LISTENS on a pool slot's port is that slot's.
  if _wt_is_pool "$slot"; then
    port=$(wt_slot_port "$slot")
    for p in $(_wt_listeners "$port"); do
      case " $out" in *" $p "*) ;; *) out="$out$p " ;; esac
    done
  fi
  printf '%s' "${out% }"
}

# _wt_listeners <port> -> pids LISTENING on it. Never `lsof -ti :<port>` for a kill: that also lists
# every CLIENT with a socket to the port -- Alice's browser on the UI, the desktop app's browser pane.
_wt_listeners() { [ -n "$1" ] && lsof -nP -t -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | sort -u; return 0; }

# 0 if <slot> is one of the pool slots in WT_SLOTS.
_wt_is_pool() {
  local pair
  for pair in $(echo "$WT_SLOTS"); do [ "${pair%%:*}" = "$1" ] && return 0; done
  return 1
}

# _wt_cwd_pids <dir> -> pids whose cwd is <dir> or below it (case-insensitive: git registered some
# paths as PR-validation, lsof reports pr-validation). Skips the caller's own process group, so a
# Bash call that cd'ed into the worktree does not kill itself.
_wt_cwd_pids() {
  local d mypg p pg
  d=$(printf '%s' "${1%/}" | tr '[:upper:]' '[:lower:]')
  mypg=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
  for p in $(lsof -d cwd -Fpn 2>/dev/null | awk -v d="$d" '
      /^p/ { p = substr($0, 2) }
      /^n/ { n = tolower(substr($0, 2)); if (n == d || index(n, d "/") == 1) print p }'); do
    pg=$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$pg" ] && [ "$pg" = "$mypg" ] && continue
    echo "$p"
  done
}

# _wt_stop_slot <slot> -- stop EVERYTHING that runs from the worktree: the launched process group,
# every process named after it or sitting in it (cwd), and the listener on its port (pool slots).
# The LE-2950 session left three servers in active2 (7864, 7872, 7874); killing only $PORT missed two.
_wt_stop_slot() {
  local slot="$1" wt="$WT_BASE/$1" lp pids p port
  lp=$(cat "$WT_BASE/.run.$slot.pid" 2>/dev/null)
  [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null && { kill -TERM -- "-$lp" 2>/dev/null || kill -TERM "$lp" 2>/dev/null; }
  port=$(wt_slot_port "$slot" 2>/dev/null)
  pids=$( { _wt_procs "$slot" | tr ' ' '\n'; echo; [ -d "$wt" ] && _wt_cwd_pids "$wt"; _wt_listeners "$port"; } | command grep -E '^[0-9]+$' | sort -u)
  [ -n "$pids" ] || { rm -f "$WT_BASE/.run.$slot.pid"; return 0; }
  for p in $(echo "$pids"); do kill -TERM "$p" 2>/dev/null; done
  sleep 2
  for p in $(echo "$pids"); do kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null; done
  [ -n "$lp" ] && kill -9 -- "-$lp" 2>/dev/null
  rm -f "$WT_BASE/.run.$slot.pid"
  echo "   stopped $slot: pid $(printf '%s' "$pids" | tr '\n' ' ')"
}

# 0 if the claim file was written by THIS Claude Code session.
_wt_mine_p() {
  local f="$1" s
  s=$(_wt_get "$f" session)
  [ -n "$s" ] && [ "$s" = "${CLAUDE_CODE_SESSION_ID:-}" ] && return 0
  s=$(_wt_get "$f" host_session)
  [ -n "$s" ] && [ "$s" = "${CLAUDE_CODE_HOST_SESSION_ID:-}" ] && return 0
  return 1
}

# 0 if we are a Claude Code session and the claim is not ours. Outside Claude Code (Alice's
# terminal) nothing is foreign: she is the one who decides.
_wt_foreign_p() {
  [ -n "${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_CODE_HOST_SESSION_ID:-}" ] || return 1
  ! _wt_mine_p "$1"
}

_wt_describe() {
  local f="$1" se sid
  se=$(_wt_get "$f" since_epoch); sid=$(_wt_get "$f" session)
  printf 'ticket=%s pr=%s since=%s' "$(_wt_get "$f" ticket)" "$(_wt_get "$f" pr)" "$(_wt_get "$f" since)"
  [ -n "$se" ] && printf ' (%s ago)' "$(_wt_dur $(( $(_wt_now) - se )))"
  printf ' session=%s host_session=%s' "${sid:-?}" "$(_wt_get "$f" host_session)"
  _wt_mine_p "$f" && printf ' (THIS session)'
  return 0
}

# For a dead keeper: is the Claude process that made the claim still up? The best hint a human has
# that the session is alive (keeper ran out its TTL, or was killed) rather than gone.
_wt_owner_hint() {
  local o
  o=$(_wt_get "$1" owner)
  if [ -z "$o" ]; then printf 'no owner recorded'
  elif kill -0 "$o" 2>/dev/null; then printf 'owner claude pid %s STILL RUNNING' "$o"
  else printf 'owner claude pid %s gone' "$o"; fi
}

# 0 = busy, 1 = free. Read-only: it never reaps.
wt_busy() {
  case "$(_wt_claim_state "$1")" in live|stale) return 0 ;; esac
  [ -n "$(_wt_procs "$1")" ] && return 0
  return 1
}

wt_status() {
  local pair slot port f st procs hb left
  printf '%-9s %-6s %s\n' SLOT PORT STATE
  for pair in $(echo "$WT_SLOTS"); do
    slot="${pair%%:*}"; port="${pair##*:}"; f="$CLAIMS/$slot"
    st=$(_wt_claim_state "$slot"); procs=$(_wt_procs "$slot")
    hb=$(_wt_mtime "$f"); hb=$(( $(_wt_now) - ${hb:-0} ))
    case "$st" in
      live)
        printf '%-9s %-6s claimed: %s keeper=%s\n' "$slot" "$port" "$(_wt_describe "$f")" "$(_wt_get "$f" pid)" ;;
      stale)
        left=$(( $(_wt_stale_secs) - hb ))
        printf '%-9s %-6s STALE claim (keeper %s gone, last heartbeat %s ago): %s\n' \
          "$slot" "$port" "$(_wt_get "$f" pid)" "$(_wt_dur "$hb")" "$(_wt_describe "$f")"
        printf '%-9s %-6s   -> %s; may still be a live session. wt_claim refuses it for %s more (--force only with Alice OK)\n' \
          "" "" "$(_wt_owner_hint "$f")" "$(_wt_dur "$left")" ;;
      expired)
        printf '%-9s %-6s EXPIRED claim (keeper gone, last heartbeat %s ago): %s -- %s; the next wt_claim reaps it\n' \
          "$slot" "$port" "$(_wt_dur "$hb")" "$(_wt_describe "$f")" "$(_wt_owner_hint "$f")" ;;
      none)
        if [ -n "$procs" ]; then
          printf '%-9s %-6s UNCLAIMED but running: pid %s\n' "$slot" "$port" "$procs"
        else
          printf '%-9s %-6s free\n' "$slot" "$port"
        fi ;;
    esac
    [ "$st" != none ] && [ -n "$procs" ] && printf '%-9s %-6s   running: pid %s\n' "" "" "$procs"
  done
  for slot in $(ls "$WT_BASE/.own" 2>/dev/null); do
    f="$WT_BASE/.own/$slot"; port=$(_wt_get "$f" port)
    printf '%-9s %-6s %s: %s%s\n' "$slot" "$port" \
      "$([ -d "$WT_BASE/$slot" ] && printf 'dedicated worktree' || printf 'port reservation (no worktree)')" \
      "$(_wt_describe "$f")" "$([ -n "$(_wt_listeners "$port")" ] && printf ' -- running')"
  done
  return 0
}

# wt_pool -- one key=value line per POOL slot, for the agent to turn into Alice's question when
# wt_up stops with "pool full" (exit 3). host_session is the desktop id (local_...): the agent looks
# it up with mcp__ccd_session_mgmt__get_session for the session title and archived/running state.
#   state:    free | live | stale | expired | unclaimed-running
#   instance: a server listens on the slot port | runner: the ticket's UI-plan runner is up |
#   results:  Alice already submitted the plan (files/runs/<ticket>-*/results.json)
wt_pool() {
  local pair slot port f st procs t
  for pair in $(echo "$WT_SLOTS"); do
    slot="${pair%%:*}"; port="${pair##*:}"; f="$CLAIMS/$slot"
    st=$(_wt_claim_state "$slot"); procs=$(_wt_procs "$slot")
    [ "$st" = none ] && { [ -n "$procs" ] && st=unclaimed-running || st=free; }
    t=$(_wt_get "$f" ticket)
    printf 'slot=%s port=%s state=%s ticket=%s pr=%s since=%s host_session=%s instance=%s runner=%s results=%s worktree=%s\n' \
      "$slot" "$port" "$st" "${t:--}" "$(_wt_get "$f" pr)" "$(_wt_get "$f" since)" "$(_wt_get "$f" host_session)" \
      "$([ -n "$(_wt_listeners "$port")" ] && echo yes || echo no)" \
      "$([ -n "$t" ] && pgrep -f "ui-plan-runner.py --plan .*plan-$t-" >/dev/null 2>&1 && echo yes || echo no)" \
      "$([ -n "$t" ] && find "$WT_PV/files/runs" -mindepth 2 -maxdepth 2 -path "*/$t-*/results.json" 2>/dev/null | command grep -q . && echo yes || echo no)" \
      "$([ -d "$WT_BASE/$slot" ] && echo present || echo MISSING)"
  done
  return 0
}

# A mkdir lock around wt_claim's look-then-write, so two sessions claiming in the same second
# cannot both pick the same slot. A lock older than 30s is a crashed claimer's: break it.
_wt_lock() {
  local l="$CLAIMS/.lock" i=0 m
  mkdir -p "$CLAIMS"
  until mkdir "$l" 2>/dev/null; do
    m=$(_wt_mtime "$l")
    if [ -n "$m" ] && [ $(( $(_wt_now) - m )) -gt 30 ]; then rmdir "$l" 2>/dev/null; continue; fi
    i=$((i + 1)); [ "$i" -gt 150 ] && { echo "wt: could not take $l" >&2; return 1; }
    sleep 0.1
  done
}
_wt_unlock() { rmdir "$CLAIMS/.lock" 2>/dev/null; return 0; }

# _wt_arm <slot> [ticket pr] -- start a fresh keeper for the slot and point the claim at it. With
# ticket/pr it writes a NEW claim; without, it re-arms an existing one (keeps ticket/since/session).
# Written to a dot-file + mv so a reader never sees half a claim (and `ls .claims` never counts it).
_wt_arm() {
  local slot="$1" f="$CLAIMS/$1" tmp="$CLAIMS/.tmp.$1.$$" old deadline kp
  deadline=$(( $(_wt_now) + $(_wt_ttl_secs) ))
  kp=$(_wt_spawn_keeper "$f" "$deadline")
  [ -n "$kp" ] || return 1
  if [ $# -ge 3 ]; then
    printf 'v=2\npid=%s\nticket=%s\npr=%s\nport=%s\nsince=%s\nsince_epoch=%s\nuntil=%s\nsession=%s\nhost_session=%s\nowner=%s\n' \
      "$kp" "$2" "$3" "$(wt_slot_port "$slot")" "$(date -Iseconds)" "$(_wt_now)" "$deadline" \
      "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_CODE_HOST_SESSION_ID:-}" "${CLAUDE_PID:-}" >| "$tmp"
  else
    old=$(_wt_get "$f" pid)
    awk -F= -v kp="$kp" -v d="$deadline" -v ow="${CLAUDE_PID:-}" '
      $1 == "v" || $1 == "pid" || $1 == "until" || $1 == "owner" { next }
      { print }
      END { print "v=2"; print "pid=" kp; print "until=" d; print "owner=" ow }' "$f" >| "$tmp"
  fi
  mv -f "$tmp" "$f" || { kill "$kp" 2>/dev/null; rm -f "$tmp"; return 1; }
  # A superseded keeper would exit on its own at its next beat; don't leave it around that long.
  [ -n "$old" ] && [ "$old" != "$kp" ] && ps -o command= -p "$old" 2>/dev/null | command grep -q wt-keeper && kill "$old" 2>/dev/null
  return 0
}

# _wt_find_mine [ticket] -> prints the slot this session holds ($SLOT first). Read-only.
# Outside Claude Code (no session id, e.g. Alice's terminal) it matches by ticket instead.
_wt_find_mine() {
  local want="$1" pair slot f
  for slot in ${SLOT:-} $(for pair in $(echo "$WT_SLOTS"); do echo "${pair%%:*}"; done); do
    f="$CLAIMS/$slot"
    [ -f "$f" ] || continue
    [ -n "$want" ] && [ "$(_wt_get "$f" ticket)" != "$want" ] && continue
    if _wt_mine_p "$f"; then echo "$slot"; return 0; fi
    if [ -z "${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_CODE_HOST_SESSION_ID:-}" ] && [ -n "$want" ]; then
      echo "$slot"; return 0
    fi
  done
  # dedicated worktrees (both slots were busy): $WT_BASE/.own/<ticket>
  for slot in $(ls "$WT_BASE/.own" 2>/dev/null); do
    f="$WT_BASE/.own/$slot"
    [ -n "$want" ] && [ "$slot" != "$want" ] && continue
    if _wt_mine_p "$f"; then echo "$slot"; return 0; fi
    if [ -z "${CLAUDE_CODE_SESSION_ID:-}${CLAUDE_CODE_HOST_SESSION_ID:-}" ] && [ -n "$want" ]; then
      echo "$slot"; return 0
    fi
  done
  return 1
}

# wt_claim [--force] <ticket> <pr-number>  -> exports SLOT, WT, PORT. Non-zero if none free.
# Takes, in order: a free slot; an EXPIRED claim (reaped); with --force, a STALE claim. Never a
# LIVE claim or a slot with a process running in it. Re-running it for the same ticket from the
# same session just re-uses (and re-arms) the slot that session already holds.
wt_claim() {
  local force="" ticket pr pair slot st="" found="" pass mine hint=""
  [ "$1" = "--force" ] && { force=1; shift; }
  ticket="${1:-?}"; pr="${2:-?}"
  mine=$(_wt_find_mine "$ticket")
  if [ -n "$mine" ] && _wt_mine_p "$CLAIMS/$mine"; then
    echo "wt_claim: this session already holds $mine for $ticket -- re-using it"
    wt_mine "$ticket"; return
  fi
  _wt_lock || return 1
  # Never clobber the caller's SLOT/WT/PORT until a slot is actually secured -- a refused claim
  # must leave an existing claim releasable.
  for pass in free expired stale; do
    [ "$pass" = stale ] && [ -z "$force" ] && break
    for pair in $(echo "$WT_SLOTS"); do
      slot="${pair%%:*}"
      st=$(_wt_claim_state "$slot")
      case "$pass:$st" in free:none|expired:expired|stale:stale) ;; *) continue ;; esac
      [ -n "$(_wt_procs "$slot")" ] && continue       # something runs there: never take it
      found="$slot"; break 2
    done
  done
  if [ -z "$found" ]; then
    _wt_unlock
    echo "No worktree slot is free:" >&2
    wt_status >&2
    for pair in $(echo "$WT_SLOTS"); do
      [ "$(_wt_claim_state "${pair%%:*}")" = stale ] && [ -z "$(_wt_procs "${pair%%:*}")" ] && hint=stale
    done
    if [ "$hint" = stale ] && [ -z "$force" ]; then
      echo "A STALE claim may belong to a session that is still alive (its app/process restarted)." >&2
      echo "STOP -- do not evict it yourself. Ask Alice; only with her OK: wt_claim --force $ticket $pr" >&2
    else
      echo "STOP -- do not evict another session. Ask Alice." >&2
    fi
    return 1
  fi
  if [ "$st" != none ]; then
    echo "wt_claim: taking over $(echo "$st" | tr a-z A-Z) claim on $found -- $(_wt_describe "$CLAIMS/$found")" >&2
  fi
  _wt_arm "$found" "$ticket" "$pr" || { _wt_unlock; echo "wt_claim: could not write the claim" >&2; return 1; }
  _wt_unlock
  SLOT="$found"
  PORT=$(wt_slot_port "$SLOT")
  WT="$WT_BASE/$SLOT"
  export SLOT WT PORT
  echo "claimed slot=$SLOT port=$PORT wt=$WT keeper=$(_wt_get "$CLAIMS/$SLOT" pid)"
  echo "(exports die with this shell -- in every later Bash call: source worktree-claim.sh && wt_mine)"
}

# wt_mine [ticket] -- run at the top of every later Bash call that touches the slot. Finds the
# claim THIS session holds, re-exports SLOT/WT/PORT, and re-arms the keeper if it is gone (Claude
# process restarted, TTL ran out) or past half its TTL. Non-zero + STOP if this session holds
# nothing: the claim was lost and the slot may already be someone else's.
wt_mine() {
  local want="$1" slot f until_ left
  slot=$(_wt_find_mine "$want")
  if [ -z "$slot" ]; then
    echo "wt_mine: this session holds no slot${want:+ for $want}. If you had claimed one, it is LOST and the" >&2
    echo "slot may belong to another session now. STOP: touch no worktree; run wt_status and tell Alice." >&2
    return 1
  fi
  f="$CLAIMS/$slot"
  if [ ! -f "$f" ] && [ -f "$WT_BASE/.own/$slot" ]; then
    SLOT="$slot"; WT="$WT_BASE/$slot"; PORT=$(_wt_get "$WT_BASE/.own/$slot" port)
    export SLOT WT PORT
    echo "dedicated worktree slot=$SLOT port=$PORT wt=$WT ticket=$(_wt_get "$WT_BASE/.own/$slot" ticket)"
    return 0
  fi
  until_=$(_wt_get "$f" until); left=0
  [ -n "$until_" ] && left=$(( until_ - $(_wt_now) ))
  if ! _wt_keeper_alive "$f" || [ "$left" -lt $(( $(_wt_ttl_secs) / 2 )) ]; then
    _wt_keeper_alive "$f" || echo "wt_mine: keeper for $slot was gone -- re-armed" >&2
    _wt_arm "$slot" || { echo "wt_mine: could not re-arm the keeper for $slot" >&2; return 1; }
  fi
  SLOT="$slot"
  PORT=$(wt_slot_port "$SLOT")
  WT="$WT_BASE/$SLOT"
  export SLOT WT PORT
  echo "slot=$SLOT port=$PORT wt=$WT ticket=$(_wt_get "$f" ticket) keeper=$(_wt_get "$f" pid)"
}

# wt_release [--force] [slot] -- release YOUR claim (default: $SLOT, else the slot this session
# holds) and stop its keeper. Refuses a claim made by another Claude Code session unless --force.
# (A bare `rm` of the claim file also works: the keeper notices at its next beat and exits.)
wt_release() {
  local force="" slot f
  [ "$1" = "--force" ] && { force=1; shift; }
  slot="${1:-${SLOT:-}}"
  [ -z "$slot" ] && slot=$(_wt_find_mine)
  [ -z "$slot" ] && { echo "no slot to release (this session holds none)" >&2; return 1; }
  f="$CLAIMS/$slot"
  if [ ! -f "$f" ] && [ -f "$WT_BASE/.own/$slot" ]; then
    if [ -z "$force" ] && _wt_foreign_p "$WT_BASE/.own/$slot"; then
      echo "wt_release: dedicated worktree $slot belongs to another session" >&2; return 1
    fi
    rm -f "$WT_BASE/.own/$slot"
    echo "released dedicated worktree $slot (dir kept at $WT_BASE/$slot; remove on sign-off: git -C \"$WT_MIRROR\" worktree remove --force \"$WT_BASE/$slot\")"
    return 0
  fi
  [ -f "$f" ] || { echo "$slot is not claimed"; return 0; }
  if [ -z "$force" ] && _wt_foreign_p "$f"; then
    echo "wt_release: $slot is NOT yours -- $(_wt_describe "$f")" >&2
    echo "Refusing. Ask Alice; only with her OK: wt_release --force $slot" >&2
    return 1
  fi
  [ -n "$(_wt_get "$f" v)" ] && _wt_keeper_alive "$f" && kill "$(_wt_get "$f" pid)" 2>/dev/null
  rm -f "$f"
  echo "released $slot"
}

# wt_env [slot] -- write the slot's .env WITHOUT destroying its Fernet secret key.
#
# 🛑 NEVER `printf ... > "$WT/.env"`. A slot's .env carries LANGFLOW_SECRET_KEY; clobbering it
# makes the instance fall back to the SHARED ~/Library/Caches/langflow/secret_key (the default
# CONFIG_DIR on macOS). That shared file has been left holding a value that is >= 32 chars but is
# NOT base64-of-32-bytes -- and ensure_fernet_key() only SHA-256s keys SHORTER than 32 chars, so a
# longer bad value is passed straight through as an invalid Fernet key. Everything boots fine and
# then EVERY credential write 500s with:
#     "Fernet key must be 32 url-safe base64-encoded bytes"
# It is silent until someone opens Model providers, saves an API key, or creates a Credential
# global variable -- i.e. it usually surfaces in Alice's hands, not in the API run.
#
# This helper: reuses the slot's existing key when it is a real Fernet key, otherwise mints one,
# and pins a PER-SLOT CONFIG_DIR so two slots never share a secret_key file at all. Knowledge bases
# live inside that config dir too (LANGFLOW_KNOWLEDGE_BASES_DIR): the default ~/.langflow/
# knowledge_bases is shared by every instance on the machine, so a slot could never be cleaned alone.
#   wt_env [--new-key] [--no-backup] [slot]    (wt_free uses both: fresh key, nothing kept)
wt_env() {
  local newkey="" backup=1 slot wt cfg key
  while [ $# -gt 0 ]; do
    case "$1" in --new-key) newkey=1; shift ;; --no-backup) backup=""; shift ;; *) break ;; esac
  done
  slot="${1:-$SLOT}"
  [ -z "$slot" ] && { echo "wt_env: no slot (claim one first)" >&2; return 1; }
  wt="$WT_BASE/$slot"
  [ -d "$wt" ] || { echo "wt_env: $wt does not exist" >&2; return 1; }
  cfg="$WT_CFG_BASE/langflow-config-$slot"
  mkdir -p "$cfg/knowledge_bases"
  key=""
  [ -z "$newkey" ] && key=$(command grep -m1 '^LANGFLOW_SECRET_KEY=' "$wt/.env" 2>/dev/null | cut -d= -f2-)
  key=$(python3 -c '
import base64, os, sys
k = (sys.argv[1] or "").strip()
try:
    if k and len(base64.urlsafe_b64decode(k + "=" * ((4 - len(k) % 4) % 4))) == 32:
        print(k); sys.exit()
except Exception:
    pass
print(base64.urlsafe_b64encode(os.urandom(32)).decode())
' "$key")
  [ -n "$backup" ] && [ -f "$wt/.env" ] && cp "$wt/.env" "$WT_BASE/.env.$slot.bak"   # backup lives OUTSIDE the worktree
  cat >| "$wt/.env" <<EOF
LANGFLOW_LOG_LEVEL=INFO
LANGFLOW_LOG_FILE=/tmp/langflow-$slot.log
LANGFLOW_AUTO_LOGIN=true
LANGFLOW_SECRET_KEY=$key
LANGFLOW_CONFIG_DIR=$cfg
LANGFLOW_KNOWLEDGE_BASES_DIR=$cfg/knowledge_bases
EOF
  echo "wrote $wt/.env (valid per-slot Fernet key, CONFIG_DIR=$cfg, KB dir inside it)"
}

# Opt-in dev mode only (make backend + vite HMR). The single-port `make run_clic` default needs
# none of this. Nothing here is hardcoded upstream: vite reads VITE_PORT (falling back to 3000) and
# takes --port, and `make backend port=N` feeds uvicorn. Exports DEV_UI_PORT / DEV_API_PORT.
#   wt_dev_ports && cd "$WT" && make backend port=$DEV_API_PORT &
#   cd "$WT/src/frontend" && VITE_PROXY_TARGET=http://localhost:$DEV_API_PORT \
#     npm run start -- --port $DEV_UI_PORT &
wt_dev_ports() {
  local slot="${1:-$SLOT}"
  case "$slot" in
    active)  DEV_UI_PORT=3000; DEV_API_PORT=7860 ;;
    active2) DEV_UI_PORT=3001; DEV_API_PORT=7861 ;;
    active3) DEV_UI_PORT=3002; DEV_API_PORT=7831 ;;
    active4) DEV_UI_PORT=3003; DEV_API_PORT=7833 ;;
    active5) DEV_UI_PORT=3004; DEV_API_PORT=7835 ;;
    *) echo "unknown slot '$slot'" >&2; return 1 ;;
  esac
  export DEV_UI_PORT DEV_API_PORT
  echo "dev ports for $slot: ui=$DEV_UI_PORT api=$DEV_API_PORT"
}

# ---------------------------------------------------------------------------
# One-command bring-up (added 2026-10-08). Everything above is unchanged.
#
#   wt_up [--force] [--ref <git-ref>] [--extras "..."] [--take <slot> | --dedicated] <ticket> <pr-number|label>
#       claim -> fetch pull/N/head -> checkout -B pr-N-qa -> scrub state -> wt_env
#       -> make run_clic port=$PORT (detached) -> wt_wait -> wt_probe
#       all 5 slots busy -> exit 3 + wt_pool; re-run with --take <slot> (Alice picked a slot to
#       free) or --dedicated (Alice chose a dedicated worktree) -- never on your own
#   wt_wait [secs]       poll /api/v1/version on $PORT; fails fast if the launched process died
#   wt_probe             POST a Credential variable: must be 201 (then deleted)
#   wt_restart           relaunch on $PORT WITHOUT rebuilding the frontend (~1 min), wait, probe
#   wt_down              stop the slot's servers; the claim, DB and checkout STAY (paused, still yours)
#   wt_free [--force] [slot]   stop + scrub to a clean warm slot + release (qa_cleanup calls it)
#   wt_warm <slot>       build a pool slot that does not exist yet (worktree + deps + frontend build)
#
# Logs: $WT_BASE/.run.<slot>.log (make/run output), /tmp/langflow-<slot>.log (app log, via .env).
WT_MIRROR="${WT_MIRROR:-$HOME/Langflow/Local-instances/main/langflow}"
WT_UP_WAIT=${WT_UP_WAIT:-420}

_wt_path() { export PATH="/opt/homebrew/bin:$HOME/bin:$PATH"; }

# Dedicated worktree: only when the pool is full AND Alice chose it (wt_up --dedicated). Lives at
# $WT_BASE/<ticket> on an even port in 7840-7852 (between the pool ranges, away from the EE range
# 7866-7898), recorded in $WT_BASE/.own/<ticket> so wt_mine/wt_status/wt_release find it and other
# sessions skip its port. Cold deps on first run (~10-15 min); qa_cleanup REMOVES it at sign-off.
# .own/ is also how a non-worktree instance reserves a port (the RC sessions' rc-1.13.0rc0 installs).
WT_OWN_PORT_LO=${WT_OWN_PORT_LO:-7840}
WT_OWN_PORT_HI=${WT_OWN_PORT_HI:-7852}
_wt_own_claim() {
  local t="$1" pr="$2" f="$WT_BASE/.own/$1" p pair taken
  mkdir -p "$WT_BASE/.own"
  p=$(_wt_get "$f" port 2>/dev/null)
  if [ -z "$p" ]; then
    p="$WT_OWN_PORT_LO"
    while [ "$p" -le "$WT_OWN_PORT_HI" ]; do
      taken=""
      for pair in $(echo "$WT_SLOTS"); do [ "${pair##*:}" = "$p" ] && taken=1; done
      if [ -z "$taken" ] && [ -z "$(_wt_listeners "$p")" ] \
         && ! find "$WT_BASE/.own" -type f -exec cat {} + 2>/dev/null | command grep -qx "port=$p"; then break; fi
      p=$((p + 2))
    done
    [ "$p" -le "$WT_OWN_PORT_HI" ] || { echo "wt: no free port in $WT_OWN_PORT_LO-$WT_OWN_PORT_HI for a dedicated worktree" >&2; return 1; }
  fi
  printf 'port=%s\nticket=%s\npr=%s\nsince=%s\nsince_epoch=%s\nsession=%s\nhost_session=%s\n' \
    "$p" "$t" "$pr" "$(date -Iseconds)" "$(_wt_now)" "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_CODE_HOST_SESSION_ID:-}" >| "$f"
  SLOT="$t"; WT="$WT_BASE/$t"; PORT="$p"; export SLOT WT PORT
  echo "   dedicated worktree slot=$SLOT port=$PORT wt=$WT"
}

_wt_kill_port() {
  local p
  for p in $(_wt_listeners "$1"); do kill -9 "$p" 2>/dev/null; done
  return 0
}

# _wt_scrub <slot> -- zero the APPLICATION state of a worktree; keep the deps. Removed: SQLite DBs
# (+ -shm/-wal/-journal), logs, test caches/reports and __pycache__ inside the tree (never under
# .venv, node_modules or .git), the per-slot config dir (secret_key, uploads, knowledge bases), the
# slot's run/app logs, pid, probe and .env backups. Kept: .venv, node_modules, the frontend build.
# The .env is rewritten by the caller (wt_env). Tracked files it removed are restored from git.
_wt_scrub() {
  local slot="$1" wt="$WT_BASE/$1"
  [ -d "$wt" ] || return 0
  find "$wt" \( -name .git -o -name .venv -o -name node_modules \) -prune -o -type f \
    \( -name '*.db' -o -name '*.db-shm' -o -name '*.db-wal' -o -name '*.db-journal' -o -name '*.sqlite' \
       -o -name '*.sqlite3' -o -name 'temp-shm' -o -name 'temp-wal' -o -name '*.log' \) -print 2>/dev/null \
    | while IFS= read -r f; do rm -f "$f"; done
  find "$wt" \( -name .git -o -name .venv -o -name node_modules \) -prune -o -type d \
    \( -name __pycache__ -o -name .pytest_cache -o -name coverage -o -name test-results -o -name playwright-report \) \
    -print 2>/dev/null | while IFS= read -r f; do
      case "$f" in "$wt"/src/frontend/*|"$wt"/.pytest_cache|"$wt"/src/*/.pytest_cache|*/__pycache__) rm -rf "$f" ;; esac
    done
  git -C "$wt" ls-files -d -z 2>/dev/null | xargs -0 git -C "$wt" checkout -q -- 2>/dev/null
  rm -rf "$WT_CFG_BASE/langflow-config-$slot"
  rm -f "$WT_BASE/.run.$slot.log" "$WT_BASE/.run.$slot.pid" "$WT_BASE/.run.$slot.sh" "$WT_BASE/.probe.$slot.json" \
        "$WT_BASE/.warm.$slot.log" "/tmp/langflow-$slot.log"
  find "$WT_BASE" -maxdepth 1 -name ".env.$slot.bak*" -delete 2>/dev/null
  return 0
}

# _wt_reset_tree <slot> -- back to a detached origin/main with no local changes and no untracked
# files; deletes the ticket's QA branch (pr-N-qa / <ticket>-qa) and the fetched pr-N ref from the
# mirror. Never touches main, release-* or any branch another worktree has checked out.
_wt_reset_tree() {
  local slot="$1" wt="$WT_BASE/$1" br pr
  [ -d "$wt" ] || return 0
  br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  git -C "$wt" checkout -q --force --detach origin/main 2>/dev/null \
    || git -C "$wt" checkout -q --force --detach main 2>/dev/null \
    || { echo "wt: could not detach $slot to origin/main" >&2; return 1; }
  git -C "$wt" clean -fdq 2>/dev/null
  case "$br" in
    pr-[0-9]*|*-qa|*-qa[0-9]*)
      git -C "$WT_MIRROR" branch -D "$br" >/dev/null 2>&1
      pr=$(printf '%s' "$br" | sed -nE 's/^pr-([0-9]+).*/\1/p')
      [ -n "$pr" ] && git -C "$WT_MIRROR" branch -D "pr-$pr" >/dev/null 2>&1 ;;
  esac
  return 0
}

# wt_free [--force] [slot] -- hand the slot back CLEAN: stop everything running from it, reset the
# tree to a detached origin/main, scrub the app state (_wt_scrub), rewrite a baseline .env with a
# fresh Fernet key, release the claim. Deps stay -- the next wt_up only reconciles them.
# Default: your own slot. --force: a slot held by another session (or unclaimed but running) -- ONLY
# the one Alice picked, after the pool-full question. While it scrubs, the slot is claimed by this
# session (ticket=FREEING), so no wt_claim can grab it half-clean. --keep: stay claimed (wt_up --take).
wt_free() {
  local force="" keep="" slot f t
  while [ $# -gt 0 ]; do
    case "$1" in --force) force=1; shift ;; --keep) keep=1; shift ;; *) break ;; esac
  done
  # no argument -> the pool slot THIS session holds (an exported $SLOT may be stale or a dedicated one)
  slot="${1:-}"
  [ -z "$slot" ] && slot=$(_wt_find_mine)
  [ -n "$slot" ] || { echo "wt_free: no slot given and this session holds none" >&2; return 1; }
  if ! _wt_is_pool "$slot"; then
    echo "wt_free: '$slot' is not a pool slot ($(echo "$WT_SLOTS" | sed 's/:[0-9]*//g')). A dedicated worktree is removed by qa_cleanup <ticket>, not freed." >&2
    return 1
  fi
  [ -d "$WT_BASE/$slot" ] || { echo "wt_free: $WT_BASE/$slot does not exist -- wt_warm $slot" >&2; return 1; }
  f="$CLAIMS/$slot"
  if [ -z "$force" ]; then
    if [ -f "$f" ] && _wt_foreign_p "$f"; then
      echo "wt_free: $slot is held by another session -- $(_wt_describe "$f")" >&2
      echo "Refusing. Only the slot Alice picks after the pool-full question: wt_free --force $slot (or wt_up --take $slot ...)" >&2
      return 1
    fi
    if [ ! -f "$f" ] && [ -n "$(_wt_procs "$slot")" ]; then
      echo "wt_free: $slot is unclaimed but running (pid $(_wt_procs "$slot")) -- someone's server. Ask Alice; only with her OK: wt_free --force $slot" >&2
      return 1
    fi
  fi
  t=$(_wt_get "$f" ticket)
  _wt_lock || return 1
  _wt_arm "$slot" FREEING - || { _wt_unlock; echo "wt_free: could not claim $slot for the scrub" >&2; return 1; }
  _wt_unlock
  echo "== free $slot${t:+ (was $t)}"
  _wt_stop_slot "$slot"
  _wt_scrub "$slot"
  _wt_reset_tree "$slot" || return 1
  wt_env --new-key --no-backup "$slot" >/dev/null || return 1
  if [ -n "$(git -C "$WT_BASE/$slot" status --porcelain 2>/dev/null)" ]; then
    echo "wt_free: $slot tree still not clean after the reset:" >&2
    git -C "$WT_BASE/$slot" status --short >&2
    return 1
  fi
  if [ -n "$keep" ]; then
    echo "   $slot clean (detached origin/main $(git -C "$WT_BASE/$slot" rev-parse --short HEAD)), still claimed by this session"
  else
    wt_release "$slot" >/dev/null
    echo "   $slot clean (detached origin/main $(git -C "$WT_BASE/$slot" rev-parse --short HEAD)) and released"
  fi
}

# wt_warm <slot> -- create a pool slot that does not exist yet, with its deps and frontend build in
# place (what makes a later wt_up take minutes instead of 10-15). Claims it as WARMING meanwhile.
# Long (npm install + uv sync + vite build): run it in the background and read $WT_BASE/.warm.<slot>.log.
wt_warm() {
  local slot="$1" wt rc
  _wt_is_pool "$slot" || { echo "usage: wt_warm <pool slot> ($(echo "$WT_SLOTS" | sed 's/:[0-9]*//g'))" >&2; return 1; }
  wt="$WT_BASE/$slot"
  _wt_path
  [ -f "$CLAIMS/$slot" ] && ! _wt_mine_p "$CLAIMS/$slot" && { echo "wt_warm: $slot is claimed -- $(_wt_describe "$CLAIMS/$slot")" >&2; return 1; }
  _wt_lock || return 1
  _wt_arm "$slot" WARMING - || { _wt_unlock; return 1; }
  _wt_unlock
  git -C "$WT_MIRROR" fetch origin --quiet || { echo "wt_warm: fetch failed" >&2; wt_release "$slot" >/dev/null; return 1; }
  if [ ! -d "$wt" ]; then
    git -C "$WT_MIRROR" worktree add -q --detach "$wt" origin/main || { echo "wt_warm: worktree add failed" >&2; wt_release "$slot" >/dev/null; return 1; }
  fi
  wt_env --new-key --no-backup "$slot" >/dev/null
  echo "== warm $slot: npm install + uv sync + frontend build (log $WT_BASE/.warm.$slot.log)"
  qa_build_acquire "$slot WARMING"
  ( cd "$wt" && make install_frontend install_backend build_frontend ) >| "$WT_BASE/.warm.$slot.log" 2>&1
  rc=$?
  qa_build_release
  if [ "$rc" != 0 ]; then
    wt_release "$slot" >/dev/null
    echo "wt_warm: make failed for $slot (rc $rc). Tail of $WT_BASE/.warm.$slot.log:" >&2
    tail -15 "$WT_BASE/.warm.$slot.log" >&2
    return 1
  fi
  _wt_scrub "$slot"
  _wt_reset_tree "$slot"            # npm install rewrites the tracked package-lock.json
  wt_release "$slot" >/dev/null
  echo "   $slot warm: .venv $(du -sh "$wt/.venv" 2>/dev/null | cut -f1), node_modules $(du -sh "$wt/src/frontend/node_modules" 2>/dev/null | cut -f1), build $([ -f "$wt/src/backend/base/langflow/frontend/index.html" ] && echo ok || echo MISSING)"
}

# _wt_launch "<shell command>" -- run it from $WT in its own session (survives the end of this
# Bash call), stdout+stderr -> .run.<slot>.log, pid -> .run.<slot>.pid
_wt_launch() {
  local cmd="$1" pid
  _wt_path
  : >| "$WT_BASE/.run.$SLOT.log"
  if command -v perl >/dev/null 2>&1; then
    pid=$( ( cd "$WT" && perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' sh -c "$cmd" \
            > "$WT_BASE/.run.$SLOT.log" 2>&1 < /dev/null & echo $! ) )
  else
    pid=$( ( cd "$WT" && nohup sh -c "$cmd" > "$WT_BASE/.run.$SLOT.log" 2>&1 < /dev/null & echo $! ) )
  fi
  printf '%s\n' "$pid" >| "$WT_BASE/.run.$SLOT.pid"
  echo "   launched pid $pid: $cmd"
}

# Time spent queued for the build lock ("[queue] waiting" is the log's last line) does not count
# against <secs>; the queue itself is capped at WT_QUEUE_MAX seconds.
WT_QUEUE_MAX=${WT_QUEUE_MAX:-3600}
wt_wait() {
  local secs="${1:-$WT_UP_WAIT}" i=0 q=0 code lp
  [ -n "${PORT:-}" ] && [ -n "${SLOT:-}" ] || { echo "wt_wait: no slot (wt_mine first)" >&2; return 1; }
  while [ "$i" -lt "$secs" ] && [ "$q" -lt "$WT_QUEUE_MAX" ]; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://localhost:$PORT/api/v1/version" 2>/dev/null)
    if [ "$code" = 200 ]; then
      echo "Langflow UP on $PORT: $(curl -s -m 5 "http://localhost:$PORT/api/v1/version")"
      return 0
    fi
    lp=$(cat "$WT_BASE/.run.$SLOT.pid" 2>/dev/null)
    if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null && [ -z "$(_wt_listeners "$PORT")" ]; then
      echo "wt_wait: the launched process ($lp) exited before serving. Tail of $WT_BASE/.run.$SLOT.log:" >&2
      tail -20 "$WT_BASE/.run.$SLOT.log" >&2
      return 1
    fi
    sleep 5
    case "$(tail -1 "$WT_BASE/.run.$SLOT.log" 2>/dev/null)" in
      *"[queue] waiting"*)
        q=$((q + 5))
        [ $((q % 60)) -eq 0 ] && echo "   ... queued ${q}s: $(tail -1 "$WT_BASE/.run.$SLOT.log" | cut -c1-110)" ;;
      *)
        i=$((i + 5))
        [ $((i % 60)) -eq 0 ] && echo "   ... ${i}s: $(tail -1 "$WT_BASE/.run.$SLOT.log" 2>/dev/null | cut -c1-110)" ;;
    esac
  done
  echo "wt_wait: no 200 from /api/v1/version after ${secs}s. Check $WT_BASE/.run.$SLOT.log, then run wt_wait again." >&2
  return 1
}

# A green /api/v1/version does NOT cover the Fernet trap; a Credential write does.
wt_probe() {
  local b="http://localhost:$PORT" tok code id out
  [ -n "${PORT:-}" ] || { echo "wt_probe: no PORT (wt_mine first)" >&2; return 1; }
  out="$WT_BASE/.probe.$SLOT.json"
  tok=$(curl -s -m 10 "$b/api/v1/auto_login" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
  [ -n "$tok" ] || { echo "wt_probe: /api/v1/auto_login gave no token (AUTO_LOGIN off? check $WT/.env)" >&2; return 1; }
  code=$(curl -s -m 10 -o "$out" -w '%{http_code}' -X POST "$b/api/v1/variables/" \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d '{"name":"QA_FERNET_PROBE","value":"probe","type":"Credential","default_fields":[]}')
  if [ "$code" = 201 ]; then
    id=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("id",""))' "$out" 2>/dev/null)
    [ -n "$id" ] && curl -s -m 10 -o /dev/null -X DELETE "$b/api/v1/variables/$id" -H "Authorization: Bearer $tok"
    rm -f "$out"
    echo "credential write: 201 (Fernet key OK)"
    return 0
  fi
  echo "wt_probe: credential write returned $code -- STOP and report. Body: $(cut -c1-200 "$out" 2>/dev/null)" >&2
  rm -f "$out"
  return 1
}

wt_restart() {
  wt_mine >/dev/null || return 1
  _wt_path
  [ -x "$WT/.venv/bin/langflow" ] || { echo "wt_restart: $WT/.venv/bin/langflow missing -- run wt_up first" >&2; return 1; }
  echo "== restart on $PORT (no rebuild)"
  _wt_kill_port "$PORT"; sleep 1
  _wt_launch "exec ./.venv/bin/langflow run --host 0.0.0.0 --port $PORT --env-file .env --frontend-path src/backend/base/langflow/frontend"
  wt_wait 300 && wt_probe
}

wt_up() {
  local force="" ref="" ticket pr branch own="" extras="" e flags="" take="" dedicated="" overcap=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force="--force"; shift ;;
      --ref) ref="$2"; shift 2 ;;
      --extras) extras="$2"; shift 2 ;;      # uv extras to add after the build (run_clic strips them)
      --take) take="$2"; shift 2 ;;          # Alice picked this busy slot to free for you
      --dedicated) dedicated=1; shift ;;     # Alice chose a dedicated worktree (pool full)
      --over-cap) overcap=1; shift ;;        # Alice said to start it even above QA_MAX_INSTANCES
      *) break ;;
    esac
  done
  ticket="${1:-}"; pr="${2:-}"
  [ -n "$ticket" ] && [ -n "$pr" ] || { echo "usage: wt_up [--force] [--ref <git-ref>] [--extras \"postgresql pgvector\"] [--take <slot> | --dedicated] [--over-cap] <ticket> <pr-number|label>" >&2; return 1; }
  _wt_path
  echo "== claim"
  if [ -f "$WT_BASE/.own/$ticket" ] && [ -d "$WT_BASE/$ticket" ] && _wt_mine_p "$WT_BASE/.own/$ticket"; then
    # a dedicated worktree this session already runs for the ticket (re-run after a dev push)
    wt_mine "$ticket" >/dev/null || return 1
    own=1
    echo "   re-using this session's dedicated worktree $SLOT ($PORT)"
  elif [ -n "$take" ]; then
    _wt_is_pool "$take" || { echo "wt_up: --take $take is not a pool slot" >&2; return 1; }
    wt_free --force --keep "$take" || { echo "wt_up: could not free $take -- STOP and report" >&2; return 1; }
    _wt_arm "$take" "$ticket" "$pr" || { echo "wt_up: could not claim $take after freeing it" >&2; return 1; }
    SLOT="$take"; PORT=$(wt_slot_port "$SLOT"); WT="$WT_BASE/$SLOT"; export SLOT WT PORT
    echo "   took $SLOT ($PORT) for $ticket"
  elif ! wt_claim $force "$ticket" "$pr" 2>/dev/null; then
    if [ -n "$dedicated" ]; then
      echo "   pool full -> dedicated worktree (Alice's choice)"
      _wt_own_claim "$ticket" "$pr" || return 1
      own=1
    else
      echo "POOL FULL -- all $(echo "$WT_SLOTS" | wc -w | tr -d ' ') slots are taken:" >&2
      wt_pool >&2
      echo "STOP. Do not evict, do not wait, do not build a worktree on your own. Ask Alice which slot to" >&2
      echo "free -- one option per slot (ticket, session title/state via get_session(host_session), instance," >&2
      echo "runner, results) plus 'dedicated worktree'. Then: wt_up --take <slot> $ticket $pr   or   wt_up --dedicated $ticket $pr" >&2
      return 3
    fi
  fi
  [ -n "${WT:-}" ] && [ -n "${PORT:-}" ] && [ -n "${SLOT:-}" ] || return 1
  echo "== stop whatever runs from $SLOT (its servers only; port $PORT)"
  _wt_stop_slot "$SLOT"
  _wt_kill_port "$PORT"
  echo "== fetch into the mirror"
  git -C "$WT_MIRROR" fetch origin --quiet || { echo "wt_up: fetch failed" >&2; return 1; }
  if [ -n "$ref" ]; then
    branch="${ticket}-qa"
  else
    git -C "$WT_MIRROR" fetch origin "pull/${pr}/head:pr-${pr}" --force --quiet \
      || { echo "wt_up: could not fetch pull/${pr}/head" >&2; return 1; }
    ref="pr-${pr}"; branch="pr-${pr}-qa"
  fi
  echo "== checkout $branch <- $ref"
  if [ -d "$WT" ]; then
    git -C "$WT" checkout -B "$branch" "$ref" --force --quiet || { echo "wt_up: checkout failed" >&2; return 1; }
  else
    git -C "$WT_MIRROR" worktree add --force -b "$branch" "$WT" "$ref" || { echo "wt_up: worktree add failed" >&2; return 1; }
  fi
  echo "   HEAD $(git -C "$WT" log -1 --format='%h %s' | cut -c1-100)"
  echo "== scrub state (DB, logs, config dir + knowledge bases of $SLOT; deps kept)"
  # Everything is per slot now (config dir, KB dir): nothing global is wiped. The old "sole claim ->
  # rm -rf ~/.langflow/knowledge_bases" counted only .claims, not dedicated worktrees -- it would have
  # wiped the KBs a dedicated-worktree session was testing.
  _wt_scrub "$SLOT"
  echo "== env"
  wt_env || return 1
  if [ -z "$overcap" ]; then
    _qa_cap_check "$PORT" "wt_up --over-cap $ticket $pr" || return 4
  fi
  echo "== make run_clic port=$PORT (detached; queued on the build lock; log $WT_BASE/.run.$SLOT.log)"
  if [ ! -d "$WT/src/frontend/node_modules" ] || [ ! -d "$WT/.venv" ]; then
    echo "   first run on this slot: cold deps + full build, allow 10+ min (wt_wait again on timeout)"
  fi
  # run_clic builds and then serves, in one make. The build lock is held from the start until the
  # server LISTENS on $PORT (= build done) or make exits -- whichever comes first.
  cat >| "$WT_BASE/.run.$SLOT.sh" <<EOF
QA_BUILD_LOCK='$QA_BUILD_LOCK'
$_QA_BUILD_FNS
qa_build_acquire '$SLOT $ticket'
make run_clic port=$PORT &
mk=\$!
while kill -0 \$mk 2>/dev/null; do
  lsof -nP -t -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && break
  sleep 3
done
qa_build_release
wait \$mk
EOF
  _wt_launch "exec sh '$WT_BASE/.run.$SLOT.sh'"
  echo "== wait"
  wt_wait "$WT_UP_WAIT" || return 1
  echo "== probe"
  wt_probe || return 1
  if [ -n "$extras" ]; then
    # make run_clic ran `uv sync --frozen`, which removed every extra; add them back and relaunch
    # from .venv/bin/langflow (wt_restart), which never re-syncs, so they survive restarts.
    for e in $(echo "$extras"); do flags="$flags --extra $e"; done
    echo "== extras: uv sync --frozen$flags"
    ( cd "$WT" && uv sync --frozen $(echo "$flags") >/dev/null 2>&1 ) || { echo "wt_up: uv sync with extras failed ($extras)" >&2; return 1; }
    wt_restart || return 1
  fi
  echo
  echo "READY  slot=$SLOT  url=http://localhost:$PORT  branch=$branch  head=$(git -C "$WT" rev-parse --short HEAD)${extras:+  extras=$extras}"
  echo "       wt=$WT"
  echo "       app log /tmp/langflow-$SLOT.log  |  make log $WT_BASE/.run.$SLOT.log"
  echo "       later shells: source ~/Langflow/pr-validation/_specs/worktree-claim.sh && wt_mine"
}

# wt_down -- PAUSE: stop the slot's servers and keep everything else (claim, DB, checkout) for the
# re-test; wt_restart brings it back. It no longer releases: a released slot must be a clean one
# (2026-10-16), and only wt_free / qa_cleanup hand a slot back. --clean is accepted and ignored.
wt_down() {
  [ "$1" = "--clean" ] && echo "wt_down: --clean is gone; the slot is cleaned by wt_free / qa_cleanup at sign-off" >&2
  wt_mine >/dev/null || return 1
  _wt_stop_slot "$SLOT"
  echo "paused $SLOT (port $PORT): servers stopped; claim, DB and checkout kept. wt_restart to resume;"
  echo "qa_cleanup <ticket> at Alice's sign-off scrubs and frees it."
}

# ---------------------------------------------------------------------------
# _qa_ticket_names <number>: filter stdin names down to QA resources of that ticket -- a qa/lf-qa
# prefix plus the ticket number as a whole token (qa-LE-2953-pg, lf-qa2953-s3, lf-qa-pg-2951).
# Never matches the standing fixtures (lf-qa-opensearch, testbed-*, langflow-nightly*).
_qa_ticket_names() {
  command grep -iE "^(qa|lf[-_]?qa)" | command grep -E "(^|[^0-9])$1([^0-9]|$)" \
    | command grep -viE "^(lf-qa-opensearch|testbed|langflow-nightly)"
}

# _qa_ticket_res <ticket> <number>: the safe front of _qa_ticket_names -- number match only for 3+
# digits, otherwise just the literal qa-<ticket>-* names.
_qa_ticket_res() {
  if printf '%s' "$2" | command grep -qE '^[0-9]{3,}$'; then _qa_ticket_names "$2"
  else awk -v p="qa-$1-" 'index($0, p) == 1'; fi
}
WT_PODMAN="${WT_PODMAN:-podman}"   # tests set WT_PODMAN=: so qa_cleanup never reaches the real podman

# qa_cleanup <ticket> -- TOTAL cleanup after Alice's sign-off (her rule, 2026-10-08): once she has
# commented the PR and the checklist is registered on the platform, nothing of the ticket is kept.
# Removes: the UI-plan runner, files/plan-<t>-*.json, files/runs/<t>-*, files/<t>-qa-findings.md,
# files/<t>-assets, files/<t>-*.md|json, the OSS slot claim (port killed, tree reverted, released)
# or the dedicated worktree (removed + branch), the EE worktree (ee_down + removed + branch), and
# containers/volumes named qa-<t>-*. Never touches lf-qa-*/testbed-*/nightly or the backlog folder.
qa_cleanup() {
  local t="$1" pv="$WT_PV" removed="" slot pair f branch ee p n
  [ -n "$t" ] || { echo "usage: qa_cleanup <ticket>" >&2; return 1; }
  _wt_path
  # 1. UI-plan runner(s) serving this ticket's plan
  for p in $(pgrep -f "ui-plan-runner.py --plan .*plan-$t-" 2>/dev/null); do
    kill "$p" 2>/dev/null && removed="$removed runner(pid $p)"
  done
  # 2. deliverables in files/ (ticket-prefixed only; "$t-" keeps LE-29 apart from LE-291)
  n=$(find "$pv/files" -mindepth 1 -maxdepth 1 \( -name "plan-$t-*" -o -name "$t" -o -name "$t-*" \) -prune -print 2>/dev/null)
  [ -n "$n" ] && { find "$pv/files" -mindepth 1 -maxdepth 1 \( -name "plan-$t-*" -o -name "$t" -o -name "$t-*" \) -prune -exec rm -rf {} + 2>/dev/null
    removed="$removed$(echo "$n" | sed "s#^$pv/# #" | tr '\n' ' ')"; }
  n=$(find "$pv/files/runs" -mindepth 1 -maxdepth 1 -name "$t-*" -prune -print 2>/dev/null)
  [ -n "$n" ] && { find "$pv/files/runs" -mindepth 1 -maxdepth 1 -name "$t-*" -prune -exec rm -rf {} + 2>/dev/null
    removed="$removed$(echo "$n" | sed "s#^$pv/# #" | tr '\n' ' ')"; }
  # 3. OSS: a POOL slot holding this ticket is scrubbed and released (wt_free) -- never removed; a
  #    dedicated worktree (pool was full, Alice chose it) is removed with its branch.
  if [ -f "$WT_BASE/.own/$t" ] && [ -d "$WT_BASE/$t" ]; then
    _wt_stop_slot "$t" >/dev/null
    branch=$(git -C "$WT_BASE/$t" rev-parse --abbrev-ref HEAD 2>/dev/null)
    git -C "$WT_MIRROR" worktree remove --force "$WT_BASE/$t" >/dev/null 2>&1 && removed="$removed worktree:$t"
    [ -n "$branch" ] && [ "$branch" != HEAD ] && git -C "$WT_MIRROR" branch -D "$branch" >/dev/null 2>&1
    rm -rf "$WT_BASE/.own/$t" "$WT_BASE/.run.$t.log" "$WT_BASE/.run.$t.pid" "$WT_BASE/.env.$t.bak" \
           "$WT_CFG_BASE/langflow-config-$t" "/tmp/langflow-$t.log"
  elif [ -f "$WT_BASE/.own/$t" ]; then
    # a port reservation without a worktree (RC installs): stop its listener, drop the reservation
    p=$(_wt_get "$WT_BASE/.own/$t" port); [ -n "$p" ] && _wt_kill_port "$p"
    rm -f "$WT_BASE/.own/$t" && removed="$removed reservation:$t${p:+(:$p)}"
  else
    for pair in $(echo "$WT_SLOTS"); do
      slot="${pair%%:*}"; f="$CLAIMS/$slot"
      [ -f "$f" ] && [ "$(_wt_get "$f" ticket)" = "$t" ] || continue
      if _wt_foreign_p "$f"; then echo "   slot $slot holds $t for ANOTHER session -- left alone" >&2; continue; fi
      wt_free "$slot" >/dev/null 2>&1 && removed="$removed slot:$slot(stopped,scrubbed,released)" \
        || echo "   wt_free $slot failed -- run it by hand to see why" >&2
    done
  fi
  # 4. EE: a POOL slot holding the ticket is scrubbed and released (ee_free), never removed; a
  #    per-ticket EE worktree (pre-pool, or --dedicated) is removed with its branch.
  if [ -f "$WT_SPECS/ee-worktree.sh" ]; then
    type ee_free >/dev/null 2>&1 || . "$WT_SPECS/ee-worktree.sh"
    for pair in $(echo "$EE_SLOTS"); do
      slot="${pair%%:*}"; f="$EE_WT_BASE/.claims/$slot"
      [ -f "$f" ] && [ "$(_wt_get "$f" ticket)" = "$t" ] || continue
      if _wt_foreign_p "$f"; then echo "   EE slot $slot holds $t for ANOTHER session -- left alone" >&2; continue; fi
      ee_free "$slot" >/dev/null 2>&1 && removed="$removed ee-slot:$slot(stopped,scrubbed,released)" \
        || echo "   ee_free $slot failed -- run it by hand to see why" >&2
    done
  fi
  ee="$EE_WT_BASE/$t"
  if [ -d "$ee" ] && [ -f "$WT_SPECS/ee-worktree.sh" ]; then
    type ee_down >/dev/null 2>&1 || . "$WT_SPECS/ee-worktree.sh"
    ee_down "$t" >/dev/null 2>&1
    # instances started by hand (no .qa-port) are found by their command line naming the worktree
    for p in $(pgrep -f "ee-worktrees/$t([^A-Za-z0-9_-]|\$)" 2>/dev/null); do kill -9 "$p" 2>/dev/null; done
    branch=$(git -C "$ee" rev-parse --abbrev-ref HEAD 2>/dev/null)
    git -C "$EE_MIRROR" worktree remove --force "$ee" >/dev/null 2>&1 && removed="$removed ee-worktree:$t"
    [ -n "$branch" ] && [ "$branch" != HEAD ] && git -C "$EE_MIRROR" branch -D "$branch" >/dev/null 2>&1
  fi
  # 5. ticket-scoped containers / volumes / networks. Convention is qa-<ticket>-<svc>, but agents
  #    have used lf-qa2953-pg, lf-qa-pg-2951, ...: anything that starts with qa/lf-qa AND carries the
  #    ticket NUMBER as a whole token is the ticket's. Standing fixtures never carry a ticket number.
  #    The number match needs 3+ digits: a short one matches fixtures (2026-10-16, a test ticket
  #    "TST-3" matched lf-qa-s3 and removed it). Anything else (RC-1.13.0, 2-digit) -> only the
  #    literal convention qa-<ticket>-<svc>.
  num=$(printf '%s' "$t" | sed -E 's/^[A-Za-z]+-//')
  #    -v: the container's ANONYMOUS volumes go with it (a postgres started without a named volume
  #    left one ~70 MB orphan per ticket -- 32 of them, 2.1 GB, cleaned on 2026-10-19). Named volumes
  #    are never touched by -v; the ticket's named ones are removed by the volume loop below.
  for n in $($WT_PODMAN ps -a --format '{{.Names}}' 2>/dev/null | _qa_ticket_res "$t" "$num"); do
    $WT_PODMAN rm -f -v "$n" >/dev/null 2>&1 && removed="$removed container:$n"
  done
  for n in $($WT_PODMAN volume ls --format '{{.Name}}' 2>/dev/null | _qa_ticket_res "$t" "$num"); do
    $WT_PODMAN volume rm "$n" >/dev/null 2>&1 && removed="$removed volume:$n"
  done
  for n in $($WT_PODMAN network ls --format '{{.Name}}' 2>/dev/null | _qa_ticket_res "$t" "$num"); do
    $WT_PODMAN network rm "$n" >/dev/null 2>&1 && removed="$removed network:$n"
  done
  echo "qa_cleanup $t removed:${removed:- nothing (no artifacts of $t found)}"
}

# qa_ports -- who listens on which QA port right now (pid + command). Run it before ANY manual
# launch and whenever a response looks like it came from the wrong server (a 409 on a fresh DB,
# data you never created). Ranges: OSS pool 7830/7832/7834/7862/7864, EE pool 7820-7828, OSS dedicated 7840-7852, EE per-ticket 7866-7898,
# nightly 7810, UI-plan runners 8900-8999, mock IdP 5557, testbed 8766/9999, OpenSearch 9201.
qa_ports() {
  local line port pid cmd
  printf '%-6s %-7s %s\n' PORT PID COMMAND
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {n=split($9,a,":"); print a[n], $2}' | sort -n -u | while read -r port pid; do
      case "$port" in 55[0-9][0-9]|78[0-9][0-9]|79[0-9][0-9]|87[0-9][0-9]|89[0-9][0-9]|9201|9999) ;; *) continue ;; esac
      cmd=$(ps -o command= -p "$pid" 2>/dev/null | command grep -oE 'worktrees/[^/ ]+|ee-worktrees/[^/ ]+|plan-[^ ]+\.json|langflow-nightly|mock_oidc|testbed|opensearch' | head -1)
      [ -n "$cmd" ] || cmd=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-70)
      printf '%-6s %-7s %s\n' "$port" "$pid" "$cmd"
    done
  return 0
}

# ---------------------------------------------------------------------------
# Instance cap (QA_MAX_INSTANCES, default 4). qa_instances lists every QA Langflow server
# listening in QA_PORT_LO-HI with its owner; _qa_cap_check stops wt_up/ee_up (exit 4) when one
# more would go over the cap; qa_pause <port> stops ONE instance and keeps everything else
# (claim, DB, checkout) -- wt_restart / ee_restart bring it back.

# _qa_port_owner <port> -> "kind:name ticket=... host_session=..." for whatever owns the port
_qa_port_owner() {
  local port="$1" pair slot f d
  for pair in $(echo "$WT_SLOTS"); do
    [ "${pair##*:}" = "$port" ] || continue
    slot="${pair%%:*}"; f="$CLAIMS/$slot"
    printf 'oss-pool:%s ticket=%s host_session=%s' "$slot" "$(_wt_get "$f" ticket)" "$(_wt_get "$f" host_session)"; return 0
  done
  for pair in $(echo "$EE_SLOTS"); do
    [ "${pair##*:}" = "$port" ] || continue
    slot="${pair%%:*}"; f="$EE_WT_BASE/.claims/$slot"
    printf 'ee-pool:%s ticket=%s host_session=%s' "$slot" "$(_wt_get "$f" ticket)" "$(_wt_get "$f" host_session)"; return 0
  done
  for f in $(find "$WT_BASE/.own" -type f -exec grep -lx "port=$port" {} + 2>/dev/null); do
    d=$(basename "$f")
    printf '%s:%s ticket=%s host_session=%s' "$([ -d "$WT_BASE/$d" ] && echo oss-dedicated || echo reservation)" \
      "$d" "$(_wt_get "$f" ticket)" "$(_wt_get "$f" host_session)"; return 0
  done
  for f in $(find "$EE_WT_BASE" -mindepth 2 -maxdepth 2 -name .qa-port -exec grep -lx "$port" {} + 2>/dev/null); do
    d=$(basename "$(dirname "$f")"); printf 'ee-worktree:%s ticket=%s' "$d" "$d"; return 0
  done
  printf 'unknown:%s' "$(ps -o command= -p "$(_wt_listeners "$port" | head -1)" 2>/dev/null | cut -c1-60)"
}

# qa_instances -- "port pid owner" per QA Langflow server listening now
qa_instances() {
  local port pid
  lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null \
    | awk -v lo="$QA_PORT_LO" -v hi="$QA_PORT_HI" 'NR>1 {n=split($9,a,":"); p=a[n]+0; if (p>=lo && p<=hi) print p, $2}' \
    | sort -n -u -k1,1 | while read -r port pid; do
      printf '%s %s %s\n' "$port" "$pid" "$(_qa_port_owner "$port")"
    done
}

# _qa_cap_check <own port> <command to re-run over the cap> -- 0 if one more instance fits
_qa_cap_check() {
  local own="$1" rerun="$2" n
  n=$(qa_instances | awk -v o="$own" '$1 != o' | wc -l | tr -d ' ')
  [ "$n" -lt "$QA_MAX_INSTANCES" ] && return 0
  echo "INSTANCE CAP -- $n QA Langflow servers already running (cap $QA_MAX_INSTANCES; this machine: 8 cores, 16 GB):" >&2
  qa_instances | awk -v o="$own" '$1 != o' | sed 's/^/   /' >&2
  echo "STOP. Ask Alice which one to pause -- one option per instance (port, ticket, session title/state via" >&2
  echo "get_session(host_session); idle/archived sessions first) plus 'start anyway'. Then: qa_pause <port> and" >&2
  echo "re-run the same command, or with her OK: $rerun" >&2
  echo "(The slot stays claimed by you meanwhile.)" >&2
  return 4
}

# qa_pause <port> -- stop the instance on <port> and keep its slot, claim, DB and checkout. Only the
# instance Alice picked after the cap question. Its session resumes it with wt_restart / ee_restart.
qa_pause() {
  local port="$1" owner kind name d p
  [ -n "$port" ] || { echo "usage: qa_pause <port>" >&2; return 1; }
  [ -n "$(_wt_listeners "$port")" ] || { echo "qa_pause: nothing listens on $port"; return 0; }
  owner=$(_qa_port_owner "$port"); kind="${owner%%:*}"; name="${owner#*:}"; name="${name%% *}"
  case "$kind" in
    oss-pool|oss-dedicated) _wt_stop_slot "$name" ;;
    ee-pool|ee-worktree)
      type _ee_stop >/dev/null 2>&1 || . "$WT_SPECS/ee-worktree.sh"
      d="$EE_WT_BASE/$name"; _ee_stop "$d"
      ( WT_BASE="$EE_WT_BASE"; CLAIMS="$EE_WT_BASE/.claims"; WT_SLOTS="$EE_SLOTS"; _wt_stop_slot "$name" ) ;;
    *)
      for p in $(_wt_listeners "$port"); do kill -TERM "$p" 2>/dev/null; done
      sleep 2
      for p in $(_wt_listeners "$port"); do kill -9 "$p" 2>/dev/null; done ;;
  esac
  sleep 1
  if [ -n "$(_wt_listeners "$port")" ]; then echo "qa_pause: $port still listening -- STOP and report" >&2; return 1; fi
  echo "paused $port ($owner) -- claim, DB and checkout kept; its session resumes it with wt_restart / ee_restart"
}
