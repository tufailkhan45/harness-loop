# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is — and isn't

This is the **source-of-truth for the harness**, not a target project. It contains a single bash runner that gets *copied into* other repos. Editing this repo means editing the runner itself; the runner has no specs of its own to drive.

The runner (`scripts/run-features.sh`) is project-agnostic: it iterates `$SPECS_DIR/<slug>/<SPEC_FILE>` (defaults `specs/<slug>/spec.md`) and invokes `claude -p` per iteration until each feature has a `.done` marker. It assumes nothing about the target project's language or test runner — Claude reads the spec (and any CLAUDE.md the target project ships) and picks the right tools.

See README.md for full operational docs (prerequisites, install steps, configuration knobs, exit codes).

## Common commands

This repo has no build, no tests, and no language toolchain — just a bash script. The "commands" here are ways to exercise the runner.

```bash
# Static check the script (only meaningful local check we have)
bash -n scripts/run-features.sh
shellcheck scripts/run-features.sh   # if installed

# Dry-run against a target project (prints resolved queue + sample prompt, no claude calls)
cd <target-project> && DRY_RUN=1 ./scripts/run-features.sh

# Single-feature smoke test (after copying the script into a target project)
cd <target-project> && MAX_ITERATIONS=2 ONLY=<slug> ./scripts/run-features.sh

# Real run
cd <target-project> && MAX_ITERATIONS=100 CLAUDE_TIMEOUT=60m ./scripts/run-features.sh

# Custom layout
cd <target-project> && SPECS_DIR=docs/specs SPEC_FILE=README.md ./scripts/run-features.sh
```

There is no test harness for the runner itself. Validate changes by creating a throwaway `specs/<slug>/spec.md` in `/tmp/` and running `DRY_RUN=1` — that exercises discovery, queue building, and prompt construction without spending any tokens.

## Architecture

Everything material is in `scripts/run-features.sh` (~300 lines). The whole design is:

- **Outer bash loop** picks the next feature without a `.done` marker, builds a prompt, invokes one `claude -p` call under `timeout`, then loops.
- **Per-iteration prompt** is assembled from: spec path, last 200 lines of the feature's prior log (`logs/feature-runner/<slug>.log`), last 200 lines of `logs/feature-runner/learnings.md`, and a fixed instruction block. The prompt asks Claude to do *one meaningful step* — not to finish the feature in one shot.
- **Verification is delegated** to Claude inside each iteration (pytest, npm test, curl, `mcp__claude-in-chrome__*`, etc.). The runner has no opinion on which tool to use; it only trusts `.done` markers.
- **State lives entirely in `logs/feature-runner/`** in the target project: per-feature `<slug>.log`, per-feature `<slug>.done` markers, cross-feature `learnings.md`, `run.log`, and the `HALT` sentinel. There is no database, no metadata store. Resume = look for missing `.done` markers.
- **Resilience signals** (each maps to a distinct exit code — see README): `timeout` per call, circuit breaker on log-size stagnation, `BLOCKED:` line in feature log, `HALT` file, hard-limit regex on stderr (`usage limit | rate limit | quota | authentication failed | invalid api key | unauthorized`).

When changing the runner, the load-bearing invariants are:

1. **The prompt is the API.** Target projects rely on `<<<PRIOR_LOG ... PRIOR_LOG` and `<<<LEARNINGS ... LEARNINGS` blocks being present and on the numbered task list. Restructure the heredoc carefully.
2. **`.done` is durable and binary.** Removing markers mid-run resurrects features. The runner trusts Claude's signal — if you weaken verification language in the prompt, you weaken the whole loop.
3. **Self-evolution is a three-part mechanism — don't break any one part.** See README's "How self-evolution works":
   - **Read** (`scripts/run-features.sh` ~lines 187-190 and 208-218): `tail -n 200` of `<slug>.log` and `learnings.md` is injected as PRIOR_LOG / LEARNINGS. Don't switch to head/middle slices — recency is the model.
   - **Write** (prompt steps 4 and 5): Claude is asked to append a progress note to the feature log every iteration, and a one-line cross-feature lesson to `learnings.md` only when broadly applicable. Don't soften this language; the loop has no other way to learn.
   - **Floor** (`scripts/run-features.sh` ~lines 274-294): the size-delta circuit breaker is the only enforcement. Without it, the loop will happily spin forever on a silent or hallucinated feedback channel. Don't disable it; tune `STUCK_LIMIT` instead.
   - Both `<slug>.log` and `learnings.md` must be append-only across iterations. Truncation breaks memory.
4. **Ordering is read every iteration** from `scripts/feature-order.txt`. Editing the order file mid-run is supported and intentional.
5. **Keep the prompt project-neutral.** Don't bake project-specific conventions or framework wording into the prompt. If a target project needs a specific workflow, it expresses that in its own CLAUDE.md, which step 1 of the prompt tells Claude to read.

## Files

| Path | Purpose |
|---|---|
| `scripts/run-features.sh` | The entire runner. |
| `scripts/feature-order.txt` | Template ordering file — comments only by default; users edit per project. |
| `.claude/settings.json` | Base read-only allowlist intended to be merged into a target project's settings. Not specific to this repo's own work. |
| `README.md` | User-facing docs (install, run, knobs, exit codes, cost expectations). |

## Constraints worth knowing before editing

- **Linux/GNU coreutils assumed.** `timeout`, `stat -c`, `df -Pm` are GNU-flavoured. Don't switch to BSD-only flags without explicit cross-platform intent.
- **`set -uo pipefail` is intentional, `set -e` is intentionally absent.** The runner must survive non-zero `claude` exits and continue iterating; adding `-e` will break the loop.
- **Per-language conventions and domain skills deliberately do not live here** (see README's "What this is NOT" section). Resist the temptation to add them — they belong in the target project.
