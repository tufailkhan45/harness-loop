# harness-loop

A drop-in headless feature runner for any STD-001 (Spec-Driven Development) project. Walks through `specs/features/*` and drives each one to a verified `.done` marker by invoking `claude -p` per iteration. Self-evolves: every iteration reads the prior attempt log + a global learnings file, so failed approaches don't get silently retried.

## What this is

`scripts/run-features.sh` is the runner. It:

- Iterates `specs/features/` in the order given by `scripts/feature-order.txt` (falls back to alphabetical for unlisted features).
- For each feature without a `.done` marker, invokes `claude -p` headlessly with a prompt that embeds:
  - The path to the spec
  - The last 200 lines of the feature's prior attempt log
  - The last 200 lines of the cross-feature learnings file
  - One-step instructions, including `/sdd/start <slug>` if no cycle exists yet
- Delegates verification to Claude — pytest, npm test, curl, `mcp__claude-in-chrome__*`, whatever fits the feature.
- Only accepts a feature as complete when Claude writes a `.done` marker AND any tests Claude was told to run pass.
- Survives stalls and crashes: per-call `timeout`, circuit breaker on stalled iterations, explicit `BLOCKED:` signal, external `HALT` file.

## Prerequisites

- `claude` CLI on `$PATH`. Tested with Claude Code 2.1.x.
- GNU `timeout` (coreutils).
- A project laid out per STD-001:
  - `specs/features/<slug>/spec.md` for each feature you want the loop to drive.
  - SDD/VKF skills installed at `.claude/skills/disrupt-sdd/` and (optionally) `.claude/skills/venture-foundation/`.
  - `.claude/state/sdd-state.yaml` initialised.

## Install into a target project

From the target project's repo root:

```bash
cp -r /home/muhammad/Dev/harness-loop/scripts ./
cp /home/muhammad/Dev/harness-loop/.claude/settings.json .claude/settings.json
chmod +x scripts/run-features.sh

# Add runtime state to .gitignore
printf '\n# Feature runner runtime state\nlogs/\n' >> .gitignore

# Optional: edit scripts/feature-order.txt to set dependency order
$EDITOR scripts/feature-order.txt
```

Merge `.claude/settings.json` with any existing one in the project — the allowlist is a base set of read-only commands that any STD-001 build benefits from.

## Run

Dry-run first to inspect the prompt and the resolved queue:

```bash
DRY_RUN=1 ./scripts/run-features.sh
```

Smoke-test on one feature:

```bash
MAX_ITERATIONS=2 ONLY=<slug> ./scripts/run-features.sh
```

Full run:

```bash
MAX_ITERATIONS=100 CLAUDE_TIMEOUT=60m ./scripts/run-features.sh
```

## Configuration knobs

| Var | Default | Purpose |
|---|---|---|
| `MAX_ITERATIONS` | `200` | Hard cap on iterations. The loop exits 0 if all features are `.done` before this. |
| `CLAUDE_TIMEOUT` | `30m` | Per-iteration timeout. Bump for features that genuinely need long runs (initial scaffolding). |
| `ONLY` | _(unset)_ | Comma-separated slug filter. Useful for smoke tests and re-running a single stuck feature. |
| `STUCK_LIMIT` | `3` | Consecutive iterations with no log growth before the circuit breaker halts the run. |
| `SLEEP_BETWEEN` | `2` | Seconds between iterations. Safety pause; harmless. |
| `ORDER_FILE` | `scripts/feature-order.txt` | Path to the order file. |
| `DRY_RUN` | `0` | Set to `1` to print the resolved queue and the prompt for the next feature, then exit. No `claude` calls. |

## How self-evolution works

Three mechanisms compound:

1. **Per-feature memory.** `logs/feature-runner/<slug>.log` captures each iteration's progress note. The next iteration on the same feature gets the last 200 lines as `<<<PRIOR_LOG ... PRIOR_LOG` in its prompt. Failed approaches don't get retried unprompted.

2. **Global learnings.** `logs/feature-runner/learnings.md` captures cross-feature lessons (env quirks, dependency gotchas, tools that worked or didn't). Every iteration on every feature reads from this. A lesson learned during feature A is available when feature D starts.

3. **Verification on every iteration.** A `.done` marker is only honoured if the verification Claude ran actually passed (per the spec's expectations). If a marker is written but tests fail, the marker is removed and the feature stays in the queue.

## Resilience

- **Per-call `timeout`.** Stalled `claude` invocations are killed; the loop continues to the next iteration.
- **Circuit breaker.** If a feature's log doesn't grow for `STUCK_LIMIT` consecutive iterations, the loop halts the entire run and writes a `HALT` file. Indicates the feature needs human attention.
- **`BLOCKED:` signal.** Claude can append a line starting with `BLOCKED:` to a feature log to halt the loop immediately when it hits something the loop can't fix (missing secret, dead external service, constitution conflict).
- **External pause.** `touch logs/feature-runner/HALT` halts the loop; `rm` resumes. The `.done` markers persist, so resume just skips already-completed features.

## Cost & time

A non-trivial run is a multi-hour, multi-million-token operation. Plan for:

- Long wall-clock time (10s of hours for a typical project).
- Real API spend.
- A machine that stays awake, plugged in, and connected.

The runner makes resume cheap (`.done` markers are durable), so you can interrupt and continue.

## Files in this folder

| Path | Purpose |
|---|---|
| `scripts/run-features.sh` | The runner. Drop into target project's `scripts/`. |
| `scripts/feature-order.txt` | Template ordering file. Edit to match the target project's dependency graph. |
| `.claude/settings.json` | Base permission allowlist for common read-only and build commands. Merge with target project's existing settings. |
| `README.md` | This file. |

## What is intentionally NOT in this folder

- Per-language `CLAUDE.md` conventions — those belong in the target project (`api/CLAUDE.md`, `web/CLAUDE.md`, etc.) because they encode the project's own stack choices.
- Domain skills (e.g. scraping playbooks, ML training conventions) — same reason.
- Constitution content — every project authors its own.

The runner is the generic part. Conventions and domain knowledge stay project-local.
