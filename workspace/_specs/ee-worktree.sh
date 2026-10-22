#!/usr/bin/env bash
# Enterprise (IBM-Langflow) PR bring-up for QA -- the EE counterpart of worktree-claim.sh.
# Encodes what the QA sessions actually run (2026-10): worktree -> uv sync -> OSS frontend mirror
# with the EE overrides (APFS-cloned from a same-pin sibling when possible) -> vite production
# build -> run-with-oss.sh over the pinned OSS -> clear the first-login password gate -> prove a
# Credential write.
#
# THE EE POOL (Alice, 2026-10-16) -- same model as the OSS pool. Five permanent, warm worktrees
# ee1..ee5 in $EE_WT_BASE on fixed ports 7820/7822/7824/7826/7828, claimed through the same claim
# machinery as the OSS slots (keeper, LIVE/STALE/EXPIRED; claims in $EE_WT_BASE/.claims). At
# sign-off qa_cleanup -> ee_free scrubs the slot (DB/config dir, qa-run.env, logs, git tree,
# servers) and releases it; .venv and the .frontend-dev mirror (node_modules) stay. All five busy ->
# ee_up exits 3 and the agent asks Alice which slot to free (--take <slot>) or whether to build a
# per-ticket worktree (--dedicated). Worktrees made before the pool (ee-worktrees/<ticket>, e.g.
# LE-2921) keep working exactly as before until their sign-off removes them.
#
#   source ~/Langflow/pr-validation/_specs/ee-worktree.sh
#   ee_up [--port N] [--merge-main] [--sso] [--fresh] [--ref <git-ref>] [--take <slot> | --dedicated] [--over-cap] <ticket> <pr-number>
#   ee_wait <ticket> [secs]   poll the bring-up (re-run after a timeout), gate + probe, print READY
#   ee_env <ticket>           export WT PORT EE_URL EE_PW in a later shell (re-arms the slot keeper)
#   ee_restart <ticket>       relaunch the backend only (no rebuild; backend-only pushes, env changes)
#   ee_down <ticket>          PAUSE: stop the instance; slot, claim, worktree and DB stay
#   ee_free [--force] [slot]  scrub a pool slot back to clean + warm and release it (qa_cleanup calls it)
#   ee_warm <slot>            build a missing/cold pool slot (worktree + uv sync + mirror + vite build)
#   ee_pool                   one key=value line per EE pool slot (input of the pool-full question)
#   ee_status                 pool + every EE worktree: head, pin, port, running or not
#
# Files inside the worktree (git-excluded): qa-run.env (env, kept across re-runs of the SAME ticket
# so the secret key and the DB survive), .qa-port, .qa-bringup.sh, .qa-run.log, .qa-run.pid,
# .langflow-dev/ (config dir + DB + knowledge bases), .frontend-dev/ (OSS@pin mirror with the
# overrides symlinked in -- the slot's "deps", kept across tickets and moved when the pin changes).
#
# Login after ee_up: admin / Qa-<ticket>-admin. The bootstrap password Boot-<ticket> in qa-run.env
# is used once, to clear the must_change_password gate.
EE_MIRROR="${EE_MIRROR:-$HOME/Langflow/Local-instances/main/Langflow-Enterprise}"
EE_WT_BASE="${EE_WT_BASE:-$HOME/Langflow/Local-instances/main/ee-worktrees}"
EE_PORT_LO=${EE_PORT_LO:-7866}     # per-ticket (pre-pool / --dedicated) worktrees only
EE_PORT_HI=${EE_PORT_HI:-7898}
EE_UP_WAIT=${EE_UP_WAIT:-480}
# claim machinery, build lock, instance cap, EE_SLOTS -- shared with the OSS pool
type _wt_arm >/dev/null 2>&1 || . "${WT_SPECS:-$HOME/Langflow/pr-validation/_specs}/worktree-claim.sh"

_ee_path() { export PATH="/opt/homebrew/bin:$HOME/bin:$HOME/.local/bin:$PATH"; export GH_HOST=github.ibm.com; }
_ee_pw()   { echo "Qa-$1-admin"; }
_ee_bootpw() { echo "Boot-$1"; }

# _ee_pool <fn> [args] -- run a worktree-claim.sh function against the EE pool (subshell: the
# caller's OSS SLOT/WT/PORT and WT_* settings are untouched).
_ee_pool() {
  ( WT_BASE="$EE_WT_BASE"; CLAIMS="$EE_WT_BASE/.claims"; WT_SLOTS="$EE_SLOTS"; WT_MIRROR="$EE_MIRROR"; "$@" )
}
_ee_is_slot()   { local p; for p in $(echo "$EE_SLOTS"); do [ "${p%%:*}" = "$1" ] && return 0; done; return 1; }
_ee_slot_port() { local p; for p in $(echo "$EE_SLOTS"); do [ "${p%%:*}" = "$1" ] && { echo "${p##*:}"; return 0; }; done; return 1; }
# _ee_slot_of <ticket> -> the pool slot whose claim names the ticket (any session)
_ee_slot_of() {
  local f
  for f in $(find "$EE_WT_BASE/.claims" -maxdepth 1 -type f ! -name '.*' 2>/dev/null); do
    [ "$(_wt_get "$f" ticket)" = "$1" ] && { basename "$f"; return 0; }
  done
  return 1
}
# _ee_wt <ticket> -> its pool slot dir, else the per-ticket worktree dir
_ee_wt() {
  local s
  s=$(_ee_slot_of "$1") && { echo "$EE_WT_BASE/$s"; return 0; }
  echo "$EE_WT_BASE/$1"
}

# Even ports from EE_PORT_LO (per-ticket worktrees); skips anything listening and anything another
# EE worktree recorded.
_ee_free_port() {
  local p="$EE_PORT_LO"
  while [ "$p" -le "$EE_PORT_HI" ]; do
    if [ -z "$(_wt_listeners "$p")" ] \
       && ! find "$EE_WT_BASE" -maxdepth 2 -name .qa-port -exec cat {} + 2>/dev/null | command grep -qx "$p"; then
      echo "$p"; return 0
    fi
    p=$((p + 2))
  done
  return 1
}

ee_env() {
  local t="$1" s
  [ -n "$t" ] || { echo "usage: ee_env <ticket>" >&2; return 1; }
  WT=$(_ee_wt "$t")
  [ -d "$WT" ] || { echo "ee_env: no worktree for $t (run ee_up; if it held a pool slot, the slot may have been freed for another ticket)" >&2; return 1; }
  PORT=$(cat "$WT/.qa-port" 2>/dev/null)
  [ -n "$PORT" ] || { echo "ee_env: $WT/.qa-port missing (run ee_up)" >&2; return 1; }
  s=$(_ee_slot_of "$t") && _wt_mine_p "$EE_WT_BASE/.claims/$s" && _ee_pool wt_mine "$t" >/dev/null 2>&1
  EE_TICKET="$t"; EE_URL="http://localhost:$PORT"; EE_PW=$(_ee_pw "$t")
  export WT PORT EE_TICKET EE_URL EE_PW
  echo "ticket=$t wt=$WT port=$PORT url=$EE_URL login=admin/$EE_PW${s:+ slot=$s}"
}

# _ee_launch <wt> "<command>" -- own session (survives this Bash call), log + pid files in the worktree.
_ee_launch() {
  local wt="$1" cmd="$2" pid
  : >| "$wt/.qa-run.log"
  if command -v perl >/dev/null 2>&1; then
    pid=$( ( cd "$wt" && perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die' sh -c "$cmd" \
            > "$wt/.qa-run.log" 2>&1 < /dev/null & echo $! ) )
  else
    pid=$( ( cd "$wt" && nohup sh -c "$cmd" > "$wt/.qa-run.log" 2>&1 < /dev/null & echo $! ) )
  fi
  printf '%s\n' "$pid" >| "$wt/.qa-run.pid"
  echo "   launched pid $pid (log $wt/.qa-run.log)"
}

# Stop only what this worktree started: its process group, plus listeners on its port whose
# command line names the worktree (the langflow process carries --frontend-path <wt>/...).
_ee_stop() {
  local wt="$1" pid port p
  pid=$(cat "$wt/.qa-run.pid" 2>/dev/null); port=$(cat "$wt/.qa-port" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 1; kill -9 -- "-$pid" 2>/dev/null
  fi
  if [ -n "$port" ]; then
    for p in $(_wt_listeners "$port"); do
      ps -o command= -p "$p" 2>/dev/null | command grep -q -- "$wt" && kill -9 "$p" 2>/dev/null
    done
  fi
  rm -f "$wt/.qa-run.pid"
  return 0
}

_ee_write_env() {   # <wt> <ticket> <port> <sso: 1|"">
  local wt="$1" t="$2" port="$3" sso="$4" f="$1/qa-run.env" key ssoval=false
  mkdir -p "$wt/.langflow-dev/knowledge_bases"
  [ -f "$wt/lfx.toml" ] && cp "$wt/lfx.toml" "$wt/.langflow-dev/"   # [services] override -> real Casbin
  if [ -f "$f" ]; then
    sed -i '' -E "s#^(LANGFLOW_PUBLIC_URL|LANGFLOW_FRONTEND_BASE_URL)=.*#\1=http://localhost:$port#" "$f"
    echo "   kept $f (secret key + DB preserved; only the port was re-pointed)"
    return 0
  fi
  [ -n "$sso" ] && ssoval=true
  key=$(python3 -c 'import base64,os;print(base64.urlsafe_b64encode(os.urandom(32)).decode())')
  {
    echo "LANGFLOW_CONFIG_DIR=$wt/.langflow-dev"
    echo "LANGFLOW_SAVE_DB_IN_CONFIG_DIR=true"
    echo "LANGFLOW_KNOWLEDGE_BASES_DIR=$wt/.langflow-dev/knowledge_bases"
    echo "LANGFLOW_SECRET_KEY=$key"
    echo "LANGFLOW_AUTO_LOGIN=false"
    echo "LANGFLOW_SUPERUSER=admin"
    echo "LANGFLOW_SUPERUSER_PASSWORD=$(_ee_bootpw "$t")"
    echo "LANGFLOW_NEW_USER_IS_ACTIVE=true"
    echo "LANGFLOW_AUTHZ_ENABLED=true"
    echo "LANGFLOW_AUTHZ_SUPERUSER_BYPASS=true"
    echo "LANGFLOW_ENTERPRISE_ALLOW_UNLICENSED_TIER_GATES=true"
    echo "LANGFLOW_SSO_ENABLED=$ssoval"
    if [ -n "$sso" ]; then
      echo "LANGFLOW_ENTERPRISE_ALLOW_UNLICENSED_SSO=true"
      echo "LANGFLOW_SSO_CONNECTION_LIMIT=unlimited"
    fi
    echo "LANGFLOW_PUBLIC_URL=http://localhost:$port"
    echo "LANGFLOW_FRONTEND_BASE_URL=http://localhost:$port"
    echo "LANGFLOW_ACCESS_SECURE=false"
    echo "LANGFLOW_REFRESH_SECURE=false"
    echo "LANGFLOW_LOG_LEVEL=INFO"
  } > "$f"
  chmod 600 "$f"
  echo "   wrote $f"
}

# The detached bring-up: everything slow, in order, with FAILED/BUILD_DONE markers ee_wait reads.
# The build part (uv sync -> mirror -> vite build) runs under the machine-wide build lock; the lock
# is released before run-with-oss. "build-only" as $1 stops after BUILD_DONE (ee_warm).
_ee_bringup_script() {   # <wt> <port> <who>
  cat <<EOF
#!/usr/bin/env bash
set -uo pipefail
export PATH="${EE_PATH_PREPEND:+$EE_PATH_PREPEND:}/opt/homebrew/bin:\$HOME/bin:\$HOME/.local/bin:\$PATH"
WT="$1"; PORT="$2"; EE_WT_BASE="$EE_WT_BASE"
QA_BUILD_LOCK='$QA_BUILD_LOCK'
$_QA_BUILD_FNS
cd "\$WT" || exit 1
log() { echo "[\$(date +%H:%M:%S)] \$*"; }
trap qa_build_release EXIT
qa_build_acquire '$3'
log "uv sync --extra dev"
uv sync --extra dev >/dev/null 2>&1 || { log "FAILED: uv sync --extra dev"; exit 1; }
PIN=\$(cat "\$WT/oss-version"); MIR="\$WT/.frontend-dev/langflow"; FE="\$MIR/src/frontend"
# find a sibling worktree whose mirror is already at this pin (APFS clone = seconds, not a cold npm install)
sibling() {
  local d
  for d in "\$EE_WT_BASE"/*/; do
    d="\${d%/}"; [ "\$d" = "\$WT" ] && continue
    if [ "\$(git -C "\$d/.frontend-dev/langflow" rev-parse HEAD 2>/dev/null)" = "\$PIN" ] && [ -d "\$d/.frontend-dev/langflow/src/frontend/node_modules" ]; then echo "\$d"; return 0; fi
  done
  return 1
}
clone_from() {
  log "frontend mirror: APFS clone from \$(basename "\$1") (same pin \${PIN:0:8})"
  rm -rf "\$WT/.frontend-dev"; mkdir -p "\$WT/.frontend-dev"
  cp -cR "\$1/.frontend-dev/langflow" "\$WT/.frontend-dev/langflow" 2>/dev/null \\
    || cp -R "\$1/.frontend-dev/langflow" "\$WT/.frontend-dev/langflow" || { log "FAILED: clone of the sibling mirror"; exit 1; }
  log "dev-frontend.sh --link-only (re-point the overrides at this worktree)"
  scripts/dev-frontend.sh --link-only >/dev/null 2>&1 || scripts/dev-frontend.sh >/dev/null 2>&1 || { log "FAILED: dev-frontend.sh"; exit 1; }
}
# A pool slot keeps its mirror across tickets; a PR with another oss-version needs the mirror moved
# (dev-frontend.sh only errors on a mismatch -- it never re-pins an existing mirror).
if [ -d "\$MIR/.git" ] && [ "\$(git -C "\$MIR" rev-parse HEAD 2>/dev/null)" != "\$PIN" ]; then
  log "frontend mirror at \$(git -C "\$MIR" rev-parse --short HEAD 2>/dev/null), oss-version pins \${PIN:0:8}: moving it"
  if SIB=\$(sibling); then
    clone_from "\$SIB"
  else
    git -C "\$MIR" fetch -q --depth 1 origin "\$PIN" && git -C "\$MIR" checkout -q --force --detach FETCH_HEAD \\
      && git -C "\$MIR" clean -fdq -- src || { log "FAILED: could not move the frontend mirror to \${PIN:0:8}"; exit 1; }
    log "dev-frontend.sh (links + npm install for the new pin)"
    scripts/dev-frontend.sh >/dev/null 2>&1 || { log "FAILED: dev-frontend.sh after moving the mirror"; exit 1; }
  fi
elif [ ! -d "\$FE/node_modules" ]; then
  if SIB=\$(sibling); then
    clone_from "\$SIB"
  else
    log "frontend mirror: dev-frontend.sh cold (clone OSS@pin + npm install, ~3 min)"
    scripts/dev-frontend.sh >/dev/null 2>&1 || { log "FAILED: dev-frontend.sh"; exit 1; }
  fi
else
  log "dev-frontend.sh --link-only"
  scripts/dev-frontend.sh --link-only >/dev/null 2>&1 || scripts/dev-frontend.sh >/dev/null 2>&1 || { log "FAILED: dev-frontend.sh"; exit 1; }
fi
STALE=\$(cd "\$FE" && find src -type l -lname '*ee-worktrees*' ! -lname "\$WT/*" 2>/dev/null | head -3)
[ -z "\$STALE" ] || { log "FAILED: override links still point at another worktree: \$STALE"; exit 1; }
log "vite build (production bundle with the EE overrides)"
( cd "\$FE" && rm -rf build && npm run build >/dev/null 2>&1 ) || { log "FAILED: npm run build (run it by hand in \$FE to see the error)"; exit 1; }
[ -f "\$FE/build/index.html" ] || { log "FAILED: no build/index.html"; exit 1; }
log "BUILD_DONE"
qa_build_release; trap - EXIT
[ "\${1:-}" = build-only ] && exit 0
log "run-with-oss.sh langflow run --port \$PORT (cold overlay installs langflow@pin, ~2 min)"
set -a; . "\$WT/qa-run.env"; set +a
exec scripts/run-with-oss.sh langflow run --host 0.0.0.0 --port "\$PORT" --frontend-path "\$FE/build"
EOF
}

_ee_token() {   # <password> -> access token or empty
  curl -s -m 15 -X POST "$EE_URL/api/v1/login" -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "username=admin" --data-urlencode "password=$1" \
    | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("access_token",""))
except Exception: print("")' 2>/dev/null
}

# First login: the bootstrap superuser is must_change_password-gated (whoami lies; /sso/settings
# tells the truth). Clear it once, then prove a Credential write (Fernet).
_ee_gate_and_probe() {
  local t="$1" tok code bootpw out id
  bootpw=$(_ee_bootpw "$t")
  tok=$(_ee_token "$EE_PW")
  if [ -z "$tok" ]; then
    tok=$(_ee_token "$bootpw")
    [ -n "$tok" ] || { echo "ee: admin login failed with both passwords (429 rate limit? wrong DB?) -- see $WT/.qa-run.log" >&2; return 1; }
    code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$EE_URL/api/v1/sso/settings" -H "Authorization: Bearer $tok")
    if [ "$code" = 403 ]; then
      curl -s -m 15 -o /dev/null -X POST "$EE_URL/api/v1/account/force-password-change" \
        -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
        -d "{\"current_password\":\"$bootpw\",\"new_password\":\"$EE_PW\"}"
      tok=$(_ee_token "$EE_PW")
      [ -n "$tok" ] || { echo "ee: password gate not cleared (force-password-change failed)" >&2; return 1; }
      echo "password gate cleared"
    fi
  fi
  out="$WT/.qa-probe.json"
  code=$(curl -s -m 10 -o "$out" -w '%{http_code}' -X POST "$EE_URL/api/v1/variables/" \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d '{"name":"QA_FERNET_PROBE","value":"probe","type":"Credential","default_fields":[]}')
  if [ "$code" = 201 ]; then
    id=$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1])).get("id",""))' "$out" 2>/dev/null)
    [ -n "$id" ] && curl -s -m 10 -o /dev/null -X DELETE "$EE_URL/api/v1/variables/$id" -H "Authorization: Bearer $tok"
    rm -f "$out"; echo "credential write: 201 (Fernet key OK)"; return 0
  fi
  echo "ee: credential write returned $code -- STOP and report. Body: $(cut -c1-200 "$out" 2>/dev/null)" >&2
  rm -f "$out"; return 1
}

_ee_ready() {
  local t="$1" s
  s=$(_ee_slot_of "$t")
  echo
  echo "READY  $EE_URL   login: admin / $EE_PW"
  echo "       ticket=$t  ${s:+slot=$s  }wt=$WT  head=$(git -C "$WT" rev-parse --short HEAD)  oss-version=$(cut -c1-8 "$WT/oss-version")"
  echo "       logs: $WT/.qa-run.log   env: $WT/qa-run.env   later shells: source ~/Langflow/pr-validation/_specs/ee-worktree.sh && ee_env $t"
  echo "       extra env var -> append to qa-run.env, then ee_restart $t"
}

# Time queued for the build lock ("[queue] waiting" last in the log) does not count against <secs>.
ee_wait() {
  local t="$1" secs="${2:-$EE_UP_WAIT}" i=0 q=0 code lp lg last
  ee_env "$t" >/dev/null || return 1
  lg="$WT/.qa-run.log"; lp=$(cat "$WT/.qa-run.pid" 2>/dev/null)
  while [ "$i" -lt "$secs" ] && [ "$q" -lt "${WT_QUEUE_MAX:-3600}" ]; do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$EE_URL/api/v1/version" 2>/dev/null)
    if [ "$code" = 200 ]; then
      echo "EE UP on $PORT: $(curl -s -m 5 "$EE_URL/api/v1/version")"
      _ee_gate_and_probe "$t" || return 1
      _ee_ready "$t"; return 0
    fi
    if command grep -q 'FAILED' "$lg" 2>/dev/null; then
      echo "ee_wait: bring-up failed:" >&2; command grep 'FAILED' "$lg" >&2; tail -15 "$lg" >&2; return 1
    fi
    if [ -n "$lp" ] && ! kill -0 "$lp" 2>/dev/null; then
      echo "ee_wait: the bring-up process exited before serving. Tail of $lg:" >&2; tail -20 "$lg" >&2; return 1
    fi
    sleep 5
    last=$(command grep '^\[' "$lg" 2>/dev/null | tail -1)
    case "$last" in
      *"[queue] waiting"*) q=$((q + 5)); [ $((q % 60)) -eq 0 ] && echo "   ... queued ${q}s: $(echo "$last" | cut -c1-110)" ;;
      *) i=$((i + 5)); [ $((i % 60)) -eq 0 ] && echo "   ... ${i}s: $(echo "$last" | cut -c1-110)" ;;
    esac
  done
  echo "ee_wait: not up after ${secs}s (cold path ~8 min). Run again: ee_wait $t" >&2
  return 1
}

# _ee_scrub <wt> -- zero a slot's APPLICATION state; keep .venv and the .frontend-dev mirror.
_ee_scrub() {
  local wt="$1"
  [ -d "$wt" ] || return 0
  rm -rf "$wt/.langflow-dev" "$wt/.langflow-dev-prod"
  rm -f "$wt/qa-run.env" "$wt/.qa-run.log" "$wt/.qa-run.pid" "$wt/.qa-probe.json" "$wt/.qa-bringup.sh"
  find "$wt" \( -name .git -o -name .venv -o -name node_modules -o -name .frontend-dev \) -prune -o -type f \
    \( -name '*.db' -o -name '*.db-shm' -o -name '*.db-wal' -o -name '*.db-journal' \) -print 2>/dev/null \
    | while IFS= read -r f; do rm -f "$f"; done
  git -C "$wt" ls-files -d -z 2>/dev/null | xargs -0 git -C "$wt" checkout -q -- 2>/dev/null
  return 0
}

# _ee_pool_arm <slot> <ticket> <pr> -- claim a pool slot for this session under the claims lock
_ee_pool_arm() { _ee_pool _ee_arm_locked "$@"; }
_ee_arm_locked() { _wt_lock || return 1; _wt_arm "$@"; local rc=$?; _wt_unlock; return $rc; }

# ee_free [--force] [--keep] [slot] -- hand an EE pool slot back CLEAN: stop everything running from
# it, scrub (DB/config dir/knowledge bases, qa-run.env, logs), reset the tree to a detached
# origin/main (+ delete qa-<ticket> and the fetched pr-N ref), release. .venv and the frontend
# mirror stay. Default: this session's slot. --force: another session's slot -- ONLY the one Alice
# picked after the pool-full question. --keep: stay claimed (ee_up --take).
ee_free() {
  local force="" keep="" slot f t pr wt br
  while [ $# -gt 0 ]; do
    case "$1" in --force) force=1; shift ;; --keep) keep=1; shift ;; *) break ;; esac
  done
  slot="${1:-}"
  [ -z "$slot" ] && slot=$(_ee_pool _wt_find_mine)
  [ -n "$slot" ] || { echo "ee_free: no slot given and this session holds no EE slot" >&2; return 1; }
  _ee_is_slot "$slot" || { echo "ee_free: '$slot' is not an EE pool slot ($(echo "$EE_SLOTS" | sed 's/:[0-9]*//g')). A per-ticket EE worktree is removed by qa_cleanup <ticket>." >&2; return 1; }
  wt="$EE_WT_BASE/$slot"; f="$EE_WT_BASE/.claims/$slot"
  [ -d "$wt" ] || { echo "ee_free: $wt does not exist -- ee_warm $slot" >&2; return 1; }
  if [ -z "$force" ]; then
    if [ -f "$f" ] && _wt_foreign_p "$f"; then
      echo "ee_free: $slot is held by another session -- $(_wt_describe "$f")" >&2
      echo "Refusing. Only the slot Alice picks after the pool-full question: ee_free --force $slot (or ee_up --take $slot ...)" >&2
      return 1
    fi
    if [ ! -f "$f" ] && [ -n "$(_ee_pool _wt_procs "$slot")" ]; then
      echo "ee_free: $slot is unclaimed but running -- someone's server. Ask Alice; only with her OK: ee_free --force $slot" >&2
      return 1
    fi
  fi
  t=$(_wt_get "$f" ticket); pr=$(_wt_get "$f" pr)
  _ee_pool_arm "$slot" FREEING - || { echo "ee_free: could not claim $slot for the scrub" >&2; return 1; }
  echo "== free EE $slot${t:+ (was $t)}"
  _ee_stop "$wt"
  _ee_pool _wt_stop_slot "$slot"
  _ee_scrub "$wt"
  br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  git -C "$wt" checkout -q --force --detach origin/main 2>/dev/null || { echo "ee_free: could not detach $slot to origin/main" >&2; return 1; }
  git -C "$wt" clean -fdq 2>/dev/null
  case "$br" in qa-*) git -C "$EE_MIRROR" branch -D "$br" >/dev/null 2>&1 ;; esac
  case "$pr" in ''|*[!0-9]*) ;; *) git -C "$EE_MIRROR" update-ref -d "refs/remotes/origin/pr-$pr" 2>/dev/null ;; esac
  _ee_slot_port "$slot" >| "$wt/.qa-port"
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    echo "ee_free: $slot tree still not clean after the reset:" >&2; git -C "$wt" status --short >&2; return 1
  fi
  if [ -n "$keep" ]; then
    echo "   $slot clean (detached origin/main $(git -C "$wt" rev-parse --short HEAD)), still claimed by this session"
  else
    _ee_pool wt_release "$slot" >/dev/null
    echo "   $slot clean (detached origin/main $(git -C "$wt" rev-parse --short HEAD)) and released"
  fi
}

# ee_warm <slot> -- create a missing EE pool slot (or re-warm a cold one): worktree on origin/main,
# uv sync, frontend mirror (APFS clone of a same-pin sibling, else cold), vite build -- under the
# build lock, claimed as WARMING meanwhile. Long: run it in the background.
ee_warm() {
  local slot="$1" wt f rc
  _ee_is_slot "$slot" || { echo "usage: ee_warm <EE pool slot> ($(echo "$EE_SLOTS" | sed 's/:[0-9]*//g'))" >&2; return 1; }
  _ee_path
  wt="$EE_WT_BASE/$slot"; f="$EE_WT_BASE/.claims/$slot"
  [ -f "$f" ] && ! _wt_mine_p "$f" && { echo "ee_warm: $slot is claimed -- $(_wt_describe "$f")" >&2; return 1; }
  _ee_pool_arm "$slot" WARMING - || return 1
  git -C "$EE_MIRROR" fetch -q origin main || { echo "ee_warm: fetch failed" >&2; _ee_pool wt_release "$slot" >/dev/null; return 1; }
  if [ ! -d "$wt" ]; then
    mkdir -p "$EE_WT_BASE"
    git -C "$EE_MIRROR" worktree add -q --detach "$wt" origin/main || { echo "ee_warm: worktree add failed" >&2; _ee_pool wt_release "$slot" >/dev/null; return 1; }
  fi
  _ee_slot_port "$slot" >| "$wt/.qa-port"
  _ee_bringup_script "$wt" "$(_ee_slot_port "$slot")" "$slot WARMING" >| "$wt/.qa-bringup.sh"; chmod +x "$wt/.qa-bringup.sh"
  echo "== warm EE $slot (log $wt/.qa-run.log)"
  ( cd "$wt" && bash "$wt/.qa-bringup.sh" build-only ) >| "$wt/.qa-run.log" 2>&1
  rc=$?
  if [ "$rc" != 0 ] || ! command grep -q BUILD_DONE "$wt/.qa-run.log"; then
    _ee_pool wt_release "$slot" >/dev/null
    echo "ee_warm: $slot failed (rc $rc):" >&2; tail -8 "$wt/.qa-run.log" >&2
    return 1
  fi
  _ee_scrub "$wt"
  git -C "$wt" checkout -q --force --detach origin/main 2>/dev/null; git -C "$wt" clean -fdq 2>/dev/null
  _ee_pool wt_release "$slot" >/dev/null
  echo "   $slot warm: .venv $(du -sh "$wt/.venv" 2>/dev/null | cut -f1), mirror $(git -C "$wt/.frontend-dev/langflow" rev-parse --short HEAD 2>/dev/null), build $([ -f "$wt/.frontend-dev/langflow/src/frontend/build/index.html" ] && echo ok || echo MISSING)"
}

ee_pool() { _ee_pool wt_pool; }

ee_up() {
  local port="" merge="" sso="" fresh="" ref="" take="" dedicated="" overcap="" t pr branch excl s="" newclaim=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --port) port="$2"; shift 2 ;;
      --merge-main) merge=1; shift ;;
      --sso) sso=1; shift ;;
      --fresh) fresh=1; shift ;;
      --ref) ref="$2"; shift 2 ;;
      --take) take="$2"; shift 2 ;;          # Alice picked this busy EE slot to free for you
      --dedicated) dedicated=1; shift ;;     # Alice chose a per-ticket worktree (pool full)
      --over-cap) overcap=1; shift ;;        # Alice said to start it even above QA_MAX_INSTANCES
      *) break ;;
    esac
  done
  t="${1:-}"; pr="${2:-}"
  [ -n "$t" ] && [ -n "$pr" ] || { echo "usage: ee_up [--port N] [--merge-main] [--sso] [--fresh] [--ref <git-ref>] [--take <slot> | --dedicated] [--over-cap] <ticket> <pr-number|label>" >&2; return 1; }
  _ee_path
  [ -d "$EE_MIRROR/.git" ] || [ -f "$EE_MIRROR/.git" ] || { echo "ee_up: EE mirror missing at $EE_MIRROR" >&2; return 1; }
  excl=$(git -C "$EE_MIRROR" rev-parse --git-common-dir)   # relative (".git") when run via -C
  case "$excl" in /*) ;; *) excl="$EE_MIRROR/$excl" ;; esac
  excl="$excl/info/exclude"
  command grep -qs '^qa-run.env$' "$excl" 2>/dev/null || printf 'qa-run.env\n.qa-*\n' >> "$excl"
  echo "== claim"
  s=$(_ee_slot_of "$t")
  if [ -z "$s" ] && [ -d "$EE_WT_BASE/$t" ]; then
    echo "   per-ticket worktree ee-worktrees/$t (made before the pool) -- re-using it"
  elif [ -n "$s" ]; then
    if _wt_foreign_p "$EE_WT_BASE/.claims/$s"; then
      echo "ee_up: EE slot $s holds $t for ANOTHER session -- $(_wt_describe "$EE_WT_BASE/.claims/$s"). STOP and tell Alice." >&2
      return 1
    fi
    _ee_pool wt_mine "$t" >/dev/null 2>&1
    echo "   this session already holds EE slot $s for $t -- re-using it (DB kept)"
  elif [ -n "$take" ]; then
    _ee_is_slot "$take" || { echo "ee_up: --take $take is not an EE pool slot" >&2; return 1; }
    ee_free --force --keep "$take" || { echo "ee_up: could not free $take -- STOP and report" >&2; return 1; }
    _ee_pool_arm "$take" "$t" "$pr" || { echo "ee_up: could not claim $take after freeing it" >&2; return 1; }
    s="$take"; newclaim=1
    echo "   took EE slot $s for $t"
  elif [ -n "$dedicated" ]; then
    echo "   pool full -> per-ticket worktree ee-worktrees/$t (Alice's choice; cold, ~8 min)"
  elif _ee_pool wt_claim "$t" "$pr" >/dev/null 2>&1; then
    s=$(_ee_slot_of "$t"); newclaim=1
    echo "   claimed EE slot $s ($(_ee_slot_port "$s"))"
  else
    echo "EE POOL FULL -- all $(echo "$EE_SLOTS" | wc -w | tr -d ' ') EE slots are taken:" >&2
    ee_pool >&2
    echo "STOP. Do not evict, do not wait, do not build a worktree on your own. Ask Alice which EE slot to" >&2
    echo "free -- one option per slot (ticket, session title/state via get_session(host_session), instance," >&2
    echo "runner, results) plus 'dedicated worktree'. Then: ee_up --take <slot> $t $pr   or   ee_up --dedicated $t $pr" >&2
    return 3
  fi
  WT="$EE_WT_BASE/${s:-$t}"; export WT
  echo "== fetch (EE mirror)"
  if [ -n "$ref" ]; then
    git -C "$EE_MIRROR" fetch -q origin main || { echo "ee_up: fetch failed" >&2; return 1; }
    # single-branch refspec: a release branch must be fetched into its tracking ref explicitly
    case "$ref" in origin/*) git -C "$EE_MIRROR" fetch -q origin "${ref#origin/}:refs/remotes/$ref" --force \
      || { echo "ee_up: could not fetch $ref" >&2; return 1; } ;; esac
    branch="qa-${t}"
  else
    git -C "$EE_MIRROR" fetch -q origin main "pull/${pr}/head:refs/remotes/origin/pr-${pr}" \
      || { echo "ee_up: could not fetch pull/${pr}/head (GH_HOST=github.ibm.com auth? PR number?)" >&2; return 1; }
    ref="origin/pr-${pr}"; branch="qa-${t}"
  fi
  echo "== worktree $WT"
  if [ -d "$WT" ]; then
    _ee_stop "$WT"
    [ -n "$s" ] && _ee_pool _wt_stop_slot "$s" >/dev/null
    [ -n "$newclaim" ] && _ee_scrub "$WT"     # a slot a new ticket takes starts from zero
    git -C "$WT" checkout -q -B "$branch" "$ref" --force || { echo "ee_up: checkout failed" >&2; return 1; }
  else
    mkdir -p "$EE_WT_BASE"
    git -C "$EE_MIRROR" worktree add -q -B "$branch" "$WT" "$ref" || { echo "ee_up: worktree add failed" >&2; return 1; }
    [ -n "$s" ] && echo "   (pool slot $s did not exist yet -- cold bring-up; ee_warm builds slots ahead of time)"
  fi
  if [ -n "$merge" ]; then
    git -C "$WT" -c user.name="QA Local" -c user.email=qa@local merge --no-edit -q origin/main \
      -m "QA-local: merge origin/main into $branch" || { echo "ee_up: merge with origin/main has conflicts -- resolve, or drop --merge-main" >&2; return 1; }
    echo "   merged origin/main ($(git -C "$EE_MIRROR" rev-parse --short origin/main))"
  fi
  echo "   HEAD $(git -C "$WT" log -1 --format='%h %s' | cut -c1-100)"
  echo "   oss-version $(cut -c1-8 "$WT/oss-version")   (origin/main: $(git -C "$EE_MIRROR" show origin/main:oss-version | cut -c1-8); different = pin bump -> check-oss-compat.sh)"
  echo "== port"
  if [ -n "$s" ]; then
    [ -n "$port" ] && echo "   --port $port ignored: pool slot $s always serves on $(_ee_slot_port "$s")"
    port=$(_ee_slot_port "$s")
  else
    [ -n "$port" ] || port=$(cat "$WT/.qa-port" 2>/dev/null)
    if [ -z "$port" ] || [ -n "$(_wt_listeners "$port")" ]; then
      [ -n "$port" ] && echo "   $port is busy (another instance) -- picking a free one"
      port=$(_ee_free_port) || { echo "ee_up: no free port in $EE_PORT_LO-$EE_PORT_HI" >&2; return 1; }
    fi
  fi
  echo "$port" >| "$WT/.qa-port"; PORT="$port"; export PORT
  echo "   $PORT${s:+ (EE slot $s)}"
  if [ -n "$fresh" ]; then rm -f "$WT"/.langflow-dev/*.db "$WT"/.langflow-dev/*.db-* 2>/dev/null; echo "   DB wiped (--fresh)"; fi
  echo "== env"
  _ee_write_env "$WT" "$t" "$PORT" "$sso"
  if [ -z "$overcap" ]; then
    _qa_cap_check "$PORT" "ee_up --over-cap $t $pr" || return 4
  fi
  echo "== bring-up (detached, queued on the build lock): uv sync -> frontend mirror + overrides -> vite build -> run-with-oss"
  _ee_bringup_script "$WT" "$PORT" "${s:-$t} $t" >| "$WT/.qa-bringup.sh"; chmod +x "$WT/.qa-bringup.sh"
  _ee_launch "$WT" "exec $WT/.qa-bringup.sh"
  ee_wait "$t"
}

ee_restart() {
  local t="$1"
  ee_env "$t" >/dev/null || return 1
  _ee_path
  [ -f "$WT/.frontend-dev/langflow/src/frontend/build/index.html" ] || { echo "ee_restart: no frontend build -- run ee_up $t" >&2; return 1; }
  echo "== restart $t on $PORT (no rebuild)"
  _ee_stop "$WT"; sleep 1
  _ee_launch "$WT" "set -a; . $WT/qa-run.env; set +a; exec $WT/scripts/run-with-oss.sh langflow run --host 0.0.0.0 --port $PORT --frontend-path $WT/.frontend-dev/langflow/src/frontend/build"
  ee_wait "$t" 300
}

# ee_down -- PAUSE: stop the instance; slot claim, worktree and DB stay (ee_restart resumes it).
ee_down() {
  local t="$1"
  ee_env "$t" >/dev/null || return 1
  _ee_stop "$WT"
  echo "paused $t on $PORT; worktree, DB and slot claim kept (ee_restart $t resumes; qa_cleanup $t at sign-off frees/removes it)"
}

ee_status() {
  local d t port st
  echo "EE POOL"
  ee_pool | sed 's/^/  /'
  echo
  printf '%-16s %-10s %-9s %-6s %s\n' WORKTREE HEAD PIN PORT STATE
  for d in "$EE_WT_BASE"/*/; do
    d="${d%/}"; t=$(basename "$d"); port=$(cat "$d/.qa-port" 2>/dev/null)
    if [ -n "$port" ] && [ -n "$(_wt_listeners "$port")" ]; then st=running; elif [ -n "$port" ]; then st=stopped; else st=-; fi
    printf '%-16s %-10s %-9s %-6s %s\n' "$t" "$(git -C "$d" rev-parse --short HEAD 2>/dev/null)" "$(cut -c1-8 "$d/oss-version" 2>/dev/null)" "${port:--}" "$st"
  done
}
