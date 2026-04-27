#!/usr/bin/env bash
# Headless, self-evolving feature runner for STD-001 (Spec-Driven Development) projects.
#
# Loops through specs/features/* and invokes `claude -p` until every feature
# has a verified .done marker. Verification is delegated to Claude — it picks
# the right tool for the job (pytest, npm test, curl, claude-in-chrome MCP for
# UI smoke tests, etc.) based on what the feature actually needs.
#
# "Self-evolving" means three things:
#   1. Each iteration reads the feature's prior attempt log AND a global
#      learnings.md, and is asked to append new lessons to both.
#   2. A circuit breaker halts the loop if a feature shows no log growth for
#      STUCK_LIMIT iterations in a row — prevents silent wheel-spinning.
#   3. Per-call timeout prevents a stalled `claude` from freezing the loop.
#
# Usage:
#   ./scripts/run-features.sh
#   MAX_ITERATIONS=200 ONLY=feature-a,feature-b ./scripts/run-features.sh
#   DRY_RUN=1 ./scripts/run-features.sh        # print plan + sample prompt, no claude calls
#
# Ordering is read from $ORDER_FILE (default: scripts/feature-order.txt).
# Features not listed there are appended alphabetically.
#
# Pause externally:  touch logs/feature-runner/HALT
# Resume:            rm   logs/feature-runner/HALT

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURES_DIR="$ROOT/specs/features"
LOG_DIR="$ROOT/logs/feature-runner"
RUN_LOG="$LOG_DIR/run.log"
LEARNINGS_FILE="$LOG_DIR/learnings.md"
HALT_FILE="$LOG_DIR/HALT"
ORDER_FILE="${ORDER_FILE:-$ROOT/scripts/feature-order.txt}"

MAX_ITERATIONS="${MAX_ITERATIONS:-200}"
ONLY="${ONLY:-}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-2}"
CLAUDE_TIMEOUT="${CLAUDE_TIMEOUT:-30m}"
STUCK_LIMIT="${STUCK_LIMIT:-3}"
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$LOG_DIR"
touch "$RUN_LOG" "$LEARNINGS_FILE"

log() {
  printf '[%s] %s\n' "$(date -Iseconds)" "$*" | tee -a "$RUN_LOG" >&2
}

trap 'log "Interrupted — exiting."; exit 130' INT TERM

preflight() {
  local fail=0
  if ! command -v claude >/dev/null 2>&1; then
    log "PREFLIGHT FAIL: claude CLI not on PATH"
    fail=1
  fi
  if ! command -v timeout >/dev/null 2>&1; then
    log "PREFLIGHT FAIL: coreutils 'timeout' not available"
    fail=1
  fi
  if [[ ! -d "$FEATURES_DIR" ]]; then
    log "PREFLIGHT FAIL: features dir missing: $FEATURES_DIR"
    fail=1
  fi
  if ! touch "$LOG_DIR/.write-test" 2>/dev/null; then
    log "PREFLIGHT FAIL: log dir not writable: $LOG_DIR"
    fail=1
  fi
  rm -f "$LOG_DIR/.write-test"
  local free_mb
  free_mb="$(df -Pm "$LOG_DIR" | awk 'NR==2 {print $4}')"
  if [[ -n "$free_mb" && "$free_mb" -lt 200 ]]; then
    log "PREFLIGHT WARN: only ${free_mb}MB free on log volume"
  fi
  return "$fail"
}

is_allowed() {
  local slug="$1"
  [[ -z "$ONLY" ]] && return 0
  IFS=',' read -r -a allow <<<"$ONLY"
  for s in "${allow[@]}"; do
    [[ "$s" == "$slug" ]] && return 0
  done
  return 1
}

build_feature_queue() {
  declare -A seen=()
  local queue=()

  if [[ -f "$ORDER_FILE" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="${line//[[:space:]]/}"
      [[ -z "$line" ]] && continue
      if [[ -d "$FEATURES_DIR/$line" && -z "${seen[$line]:-}" ]]; then
        queue+=("$line")
        seen[$line]=1
      fi
    done <"$ORDER_FILE"
  fi

  for dir in "$FEATURES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local slug
    slug="$(basename "$dir")"
    if [[ -z "${seen[$slug]:-}" ]]; then
      queue+=("$slug")
      seen[$slug]=1
    fi
  done

  printf '%s\n' "${queue[@]}"
}

find_next_feature() {
  while IFS= read -r slug; do
    [[ -z "$slug" ]] && continue
    [[ -f "$LOG_DIR/$slug.done" ]] && continue
    is_allowed "$slug" || continue
    echo "$slug"
    return 0
  done < <(build_feature_queue)
  return 1
}

filesize() {
  [[ -f "$1" ]] && stat -c '%s' "$1" 2>/dev/null || echo 0
}

if ! preflight; then
  log "Preflight failed — aborting before any iteration."
  exit 2
fi

log "Resolved feature queue (in execution order):"
queue_preview="$(build_feature_queue)"
while IFS= read -r slug; do
  [[ -z "$slug" ]] && continue
  marker=""
  [[ -f "$LOG_DIR/$slug.done" ]] && marker=" [done]"
  is_allowed "$slug" || marker="$marker [filtered out by ONLY]"
  log "  - $slug$marker"
done <<<"$queue_preview"

declare -A stuck_count

iteration=0
while (( iteration < MAX_ITERATIONS )); do
  iteration=$((iteration + 1))

  if [[ -f "$HALT_FILE" ]]; then
    log "HALT file present at $HALT_FILE — pausing. Remove it to resume."
    exit 3
  fi

  log "=== iteration $iteration / $MAX_ITERATIONS ==="

  if ! slug="$(find_next_feature)"; then
    log "All features marked .done — runner exiting successfully."
    exit 0
  fi

  spec_path="$FEATURES_DIR/$slug/spec.md"
  feature_log="$LOG_DIR/$slug.log"
  done_marker="$LOG_DIR/$slug.done"
  touch "$feature_log"

  log "Target feature: $slug (stuck count: ${stuck_count[$slug]:-0}/$STUCK_LIMIT)"

  size_before="$(filesize "$feature_log")"

  prior_context=""
  [[ -s "$feature_log" ]] && prior_context="$(tail -n 200 "$feature_log")"
  global_learnings=""
  [[ -s "$LEARNINGS_FILE" ]] && global_learnings="$(tail -n 200 "$LEARNINGS_FILE")"

  prompt=$(cat <<EOF
You are working headlessly (no interactive user) on the feature '$slug'.
Repo root: $ROOT
Spec to satisfy: $spec_path

You have access to the full Claude Code toolset, including:
  - Bash for running pytest / npm test / curl / docker / db migrations
  - Read/Edit/Write for code changes
  - mcp__claude-in-chrome__* for browser-based smoke tests of UI features
    (use it when the feature is user-facing and unit tests can't fully verify it)
  - Web search/fetch for checking documentation
Pick whichever verification path actually proves the feature works. Don't fake
it — a passing trivial test is worse than no test.

Prior attempt log for THIS feature (last 200 lines — may be empty on first run).
Treat it as lessons-learned. Do not repeat failed approaches without new info:
<<<PRIOR_LOG
$prior_context
PRIOR_LOG

Global learnings accumulated across all features so far:
<<<LEARNINGS
$global_learnings
LEARNINGS

YOUR TASK FOR THIS INVOCATION (one meaningful step only — the outer loop will
call you again):

1. Read $spec_path. If no SDD change cycle exists for this feature, start one
   with /sdd/start $slug.
2. Execute the next unfinished task from the active cycle. Follow STD-001 and
   the repo's CLAUDE.md. If the request conflicts with the project's
   constitution (specs/constitution/), STOP and record the conflict in the log
   instead of implementing.
3. Verify your change with whatever tool fits — write or run unit tests, hit
   an endpoint with curl, drive the UI through claude-in-chrome, etc.
4. Append a progress note to $feature_log (≤ 40 lines): what you tried,
   observed result, errors with key snippets, what to try next.
5. If — and only if — anything you discovered would also help OTHER features
   (env quirk, dependency gotcha, tool that worked, tool that didn't), append
   a one-line lesson to $LEARNINGS_FILE prefixed with the date.
6. ONLY if this feature is fully complete — all cycle tasks done, verification
   green, spec satisfied — write a one-line summary to $done_marker. Do not
   write the marker otherwise; the outer loop trusts this signal.

Rules:
- Never bypass SDD or VKF workflows defined in CLAUDE.md.
- Do not attempt multiple features in one invocation.
- If you are blocked by something the loop should know (broken env, missing
  secret, external service down), append a line starting "BLOCKED:" to
  $feature_log so the next iteration sees it immediately.
EOF
)

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1 — printing the prompt for '$slug' and exiting without invoking claude."
    printf -- '----- PROMPT (feature=%s) -----\n%s\n----- END PROMPT -----\n' "$slug" "$prompt"
    exit 0
  fi

  log "Invoking claude (timeout=$CLAUDE_TIMEOUT)"
  timeout "$CLAUDE_TIMEOUT" claude -p "$prompt" --permission-mode bypassPermissions 2>&1 \
    | tee -a "$feature_log"
  rc=${PIPESTATUS[0]}
  case "$rc" in
    0)   log "claude exited 0" ;;
    124) log "claude TIMED OUT after $CLAUDE_TIMEOUT — killed" ;;
    *)   log "claude exited $rc" ;;
  esac
  printf '[%s] claude exit=%s\n' "$(date -Iseconds)" "$rc" >>"$feature_log"

  size_after="$(filesize "$feature_log")"
  if (( size_after <= size_before + 32 )); then
    stuck_count[$slug]=$(( ${stuck_count[$slug]:-0} + 1 ))
    log "No meaningful log growth for '$slug' (stuck ${stuck_count[$slug]}/$STUCK_LIMIT)"
  else
    stuck_count[$slug]=0
  fi

  if grep -q '^BLOCKED:' "$feature_log" 2>/dev/null; then
    log "Feature '$slug' reported BLOCKED — see $feature_log. Halting run."
    touch "$HALT_FILE"
    exit 4
  fi

  if (( ${stuck_count[$slug]:-0} >= STUCK_LIMIT )); then
    log "CIRCUIT BREAKER: '$slug' stuck $STUCK_LIMIT iterations with no progress. Halting run."
    {
      echo "## Circuit breaker tripped on $slug at $(date -Iseconds)"
      echo "After $STUCK_LIMIT iterations the feature log stopped growing."
      echo "Investigate $feature_log, fix the underlying issue, then rerun."
    } >>"$RUN_LOG"
    touch "$HALT_FILE"
    exit 5
  fi

  if [[ -f "$done_marker" ]]; then
    log "Feature '$slug' marker present — accepting Claude's verification."
    stuck_count[$slug]=0
  fi

  sleep "$SLEEP_BETWEEN"
done

if ! find_next_feature >/dev/null; then
  log "Hit MAX_ITERATIONS=$MAX_ITERATIONS, but all eligible features are .done — exiting clean."
  exit 0
fi
log "Reached MAX_ITERATIONS=$MAX_ITERATIONS with features still pending."
exit 1
