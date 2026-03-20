# OpusDex

OpusDex is a Bash-based AI development orchestrator. It runs a target Git repository through a structured workflow that combines Claude Code CLI for planning and review, OpenAI Codex CLI for implementation/testing/documentation/commit creation, and an optional Cursor agent CLI live-validation pass.

The orchestrator itself lives in this repository. Session state, memory, logs, and build history are written into the target project under `.opusdex/`, so each project keeps its own execution history.

## What It Does

- Starts from a task description and a target project path.
- Creates a per-project working area for plans, outputs, logs, memory, and build history.
- Runs a repeatable phase pipeline across multiple AI CLIs.
- Preserves session artifacts for later inspection or phase resumption.
- Encourages project-specific agent and skill discovery from the target repository.
- Records reusable "lessons" across sessions.

## Workflow Overview

The main entry point is [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh). Its top-level execution flow is:

1. Parse CLI arguments.
2. Validate required inputs and commands.
3. Resolve the target project path and verify it is a Git repository.
4. Initialize `.opusdex/` inside the target project.
5. Record the baseline commit and session metadata.
6. Run the configured phase sequence.
7. Merge any lessons into persistent memory and append a build-log entry.

### Phase Sequence

The current top-level phase order is:

1. `plan`
2. `build`
3. `review`
4. `live`
5. `document`
6. `commit`

`review` is the normal entrypoint into the review/live workflow. The separate `live` phase slot exists so interrupted sessions can resume directly into the live-validation loop with `--phase live`.

### Phase Responsibilities

| Phase | Tool | Mode | Main purpose | Expected session artifact |
| --- | --- | --- | --- | --- |
| Plan | Claude Code CLI | Interactive | Explore the target repo with the user and write an implementation plan | `todo.md` |
| Build | Codex CLI | Non-interactive exec | Apply the agreed plan and run tests in one session | `build_output.md`, `test_results.md` |
| Review | Claude Code CLI | Non-interactive JSON output | Review the diff and produce a verdict | `review_output.json`, `review.md` |
| Live | Cursor agent CLI | Non-interactive prompt | Run the app, inspect logs, smoke-test, and optionally attempt targeted runtime fixes | `live_output_<n>.md`, `live_results.md`, `live_feedback.md` |
| Fix | Codex CLI | Non-interactive exec | Address review feedback and retest | `fix_output.md`, `test_results.md` |
| Post-Live Verify | Codex CLI | Non-interactive exec | Re-run formal tests after Cursor-authored live fixes | `retest_after_live_output.md`, `test_results.md` |
| Document | Codex CLI | Non-interactive exec | Update documentation or comments | `document_output.md` |
| Commit | Codex CLI | Non-interactive exec | Stage relevant files and create a local commit | `commit_output.md` |

### Retry and Gating Behavior

- `review` is wrapped by `phase_review_with_gate`.
- If review returns `REQUEST_CHANGES` or `BLOCK` and retries remain, OpusDex runs `fix`, then re-reviews.
- The live pass is optional unless `--auto-live` or `--phase live` is used.
- Inside the live pass, Cursor gets up to `LIVE_RETRY_LIMIT` attempts to diagnose, fix, restart, and revalidate runtime issues.
- If Cursor still fails, OpusDex feeds the live failure context into Claude review, runs Codex fixes if needed, then re-enters live validation. That outer review/live loop is capped by `LIVE_REVIEW_LIMIT`.
- If Cursor gets the app healthy by changing tracked files, OpusDex runs a formal Codex verification pass, re-reviews the diff, and then requires one more clean live validation pass before continuing.
- `commit` is gated by a confirmation prompt unless `--auto-commit` is used.

## Requirements

OpusDex assumes a Unix-like environment with standard shell utilities. Based on the current code, you should have:

- Bash 4+.
- `git`
- `jq`
- Claude Code CLI
- OpenAI Codex CLI
- Cursor agent CLI, only when the live pass is enabled
- Standard utilities such as `cat`, `date`, `grep`, `head`, `mktemp`, `sed`, `seq`, `tail`, `tee`, and `tr`

The target project must already be a Git repository.

## Installation and Setup

There is no installer script in this repository. Setup is manual:

1. Clone this repository.
2. Review and edit [`config.env`](/root/github/opusdex/config.env).
3. Make sure the configured Claude and Codex CLI binaries exist and are authenticated. If you plan to use the live pass, Cursor agent CLI should also be installed and authenticated.
4. Run [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh) against a target project.

The current default configuration is:

| Setting | Default |
| --- | --- |
| `CLAUDE_MODEL` | `opus` |
| `CLAUDE_EFFORT` | `high` |
| `CODEX_MODEL` | `gpt-5.4` |
| `CODEX_EFFORT` | `xhigh` |
| `CURSOR_MODEL` | `composer-2` |
| `AUTO_PLAN` | `false` |
| `AUTO_LIVE` | `false` |
| `AUTO_COMMIT` | `false` |
| `TEST_RETRY_LIMIT` | `3` |
| `REVIEW_RETRY_LIMIT` | `1` |
| `LIVE_RETRY_LIMIT` | `3` |
| `LIVE_REVIEW_LIMIT` | `2` |
| `CODEX_YOLO_FLAG` | `--yolo` |
| `CURSOR_YOLO_FLAG` | `--yolo` |

Default binary paths are also defined in [`config.env`](/root/github/opusdex/config.env):

- `CLAUDE_BIN="/root/.local/bin/claude"`
- `CODEX_BIN="/root/.nvm/versions/node/v25.8.1/bin/codex"`
- `CURSOR_BIN="/root/.local/bin/agent"`

`config.env` respects pre-set environment variables, so tests or wrapper scripts can override these defaults without editing the file.

## Usage

```bash
./orchestrate.sh "task description" --project /path/to/project [options]
```

### CLI Options

| Option | Meaning |
| --- | --- |
| `--project PATH` | Target project directory. Required. |
| `--auto-plan` | Skip the plan approval prompt. |
| `--auto-live` | Skip the live-pass confirmation prompt. |
| `--auto-commit` | Skip the interactive commit confirmation prompt. |
| `--phase PHASE` | Resume from a specific phase. Earlier phases are skipped. |
| `--claude-model MODEL` | Override the Claude model for this run. |
| `--claude-effort LEVEL` | Override Claude reasoning effort. |
| `--codex-model MODEL` | Override the Codex model for this run. |
| `--codex-effort LEVEL` | Override Codex reasoning effort. |
| `--cursor-model MODEL` | Override the Cursor agent model for the live pass (default: `composer-2`). |
| `-h`, `--help` | Show usage text. |

### Example Commands

Run a full session:

```bash
./orchestrate.sh "Add CSV import support" --project /root/src/myapp
```

Resume the live workflow after an interrupted run:

```bash
./orchestrate.sh "Add CSV import support" --project /root/src/myapp --phase live
```

Skip the commit confirmation prompt:

```bash
./orchestrate.sh "Update onboarding copy" --project /root/src/myapp --auto-commit
```

## Runtime Behavior

### Session Setup

At startup, OpusDex computes:

- `PROJECT_DATA_DIR="$PROJECT_PATH/.opusdex"`
- `SESSION_ID="$(date '+%Y%m%d_%H%M%S')"`
- `SESSION_TASK_DIR="$PROJECT_DATA_DIR/tasks/$SESSION_ID"`
- `BASELINE_COMMIT="$(git -C "$PROJECT_PATH" rev-parse HEAD)"`

It then writes the task description to `task.txt` inside the session directory and redirects all orchestrator stdout/stderr through `tee` into a session log file.

### Logging

[`lib/logging.sh`](/root/github/opusdex/lib/logging.sh) provides:

- phase banners
- color-coded log levels
- per-phase color mapping

Logs for each session are written to:

```text
$PROJECT_PATH/.opusdex/logs/session_<session_id>.log
```

### Prompt Assembly

Prompt construction lives in [`lib/prompts.sh`](/root/github/opusdex/lib/prompts.sh).

For most phases, OpusDex:

1. Loads a template from `prompts/<phase>.md`.
2. Replaces placeholder variables.
3. Writes the final prompt to a temporary file in `/tmp`.
4. Passes the prompt text to Claude, Codex, or Cursor.

Plan is special: it uses separate system and task prompts from [`prompts/plan_system.md`](/root/github/opusdex/prompts/plan_system.md) and [`prompts/plan_task.md`](/root/github/opusdex/prompts/plan_task.md).

The current placeholder sources are:

| Placeholder | Source |
| --- | --- |
| `{{MEMORY}}` | Output of `read_memory()` |
| `{{TASK}}` | Task description passed on the command line |
| `{{PROJECT_PATH}}` | Absolute target project path |
| `{{SESSION_TASK_DIR}}` | Session artifact directory |
| `{{CONTEXT}}` | `todo.md` for `build`; `test_results.md` for `review`, `fix_and_retest`, `retest_after_live`, and `live` |
| `{{CHANGES}}` | `git diff --name-only` from baseline to `HEAD`, with working-tree fallback |
| `{{DIFF}}` | Diff summary (`--name-only` + `--stat`) from baseline to `HEAD`, with working-tree fallback |
| `{{REVIEW}}` | Contents of `review.md`, if present |
| `{{LIVE_FEEDBACK}}` | Contents of `live_feedback.md`, if present |
| `{{REVIEW_ROUND}}` | Current review round number |
| `{{LIVE_ATTEMPT}}` | Current live-attempt number |

### Memory Model

Memory management lives in [`lib/memory.sh`](/root/github/opusdex/lib/memory.sh).

Each target project gets a shared memory file — `memory/shared_context.md` — injected into every prompt via `{{MEMORY}}`.

At session finalization, OpusDex looks for `lessons.md` in the session directory. Any sections beginning with `### Rule:` are merged into `shared_context.md`.

If a project still has legacy `memory/claude_lessons.md` or `memory/codex_lessons.md` files, OpusDex migrates their rule blocks into `shared_context.md` during setup instead of silently ignoring them.

Memory curation is AI-assisted, but replacements are validated before they overwrite the shared context. If the curated output is structurally incomplete, OpusDex falls back to deterministic rule merging.

### Review Verdict Parsing

The review phase expects `review.md` to contain a verdict line matching one of:

- `Verdict: APPROVE`
- `Verdict: REQUEST_CHANGES`
- `Verdict: BLOCK`

If Claude does not write `review.md` directly, OpusDex extracts `.result`, `.content`, or the raw JSON payload from `review_output.json` and writes that into `review.md` before parsing the verdict.

## Project Data Layout

The orchestrator keeps project-specific state under:

```text
<target-project>/.opusdex/
├── .gitignore
├── builds/
│   └── build_log.md
├── logs/
│   └── session_<session_id>.log
├── memory/
│   └── shared_context.md
└── tasks/
    └── <session_id>/
        ├── task.txt
        ├── todo.md
        ├── build_output.md
        ├── test_results.md
        ├── review_output.json
        ├── review.md
        ├── live_output_<n>.md
        ├── live_results.md
        ├── live_feedback.md
        ├── fix_output.md
        ├── retest_after_live_output.md
        ├── document_output.md
        ├── commit_output.md
        └── lessons.md
```

Not every session will contain every file. For example, `fix_output.md` appears only if a fix pass runs.

### Build Log Entries

After the phase pipeline completes, [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh) appends an entry to:

```text
$PROJECT_PATH/.opusdex/builds/build_log.md
```

Each entry includes:

- timestamp
- session ID
- original task text
- AI-generated session summary
- final status
- latest commit hash and subject line
- session duration

## AI Tool Integration

### Claude Usage

Claude is used for:

- interactive planning
- review
- build-log memory/session summarization and memory curation

Current execution behavior:

- plan runs from the target project directory
- review runs from the target project directory
- both Claude invocations use `--dangerously-skip-permissions`

### Codex Usage

Codex is used for:

- build
- fix
- post-live verification
- document
- commit

Current execution behavior:

- every Codex phase uses `codex exec`
- every Codex phase runs with `-C "$PROJECT_PATH"`
- every Codex phase passes the configured reasoning effort
- every Codex phase uses the configured YOLO flag, which defaults to `--yolo`

### Cursor Usage

Cursor agent CLI is used for:

- optional live validation
- runtime diagnosis and targeted live-fix attempts

Current execution behavior:

- Cursor is only required when the live phase is actually entered
- the live phase runs from the target project directory
- Cursor may retry runtime fixes up to `LIVE_RETRY_LIMIT`
- if Cursor changes tracked files and reaches a passing live verdict, OpusDex runs a Codex verification pass and a Claude review before requiring one more clean live pass

## Project-Defined Agents and Skills

The prompts and working-directory choices are designed so OpusDex can leverage instructions that belong to the target project rather than the orchestrator itself.

### Claude-side discovery

Because Claude phases run with `cwd` set to the target project, Claude can auto-discover:

- `CLAUDE.md`
- `.claude/agents/<name>/AGENT.md`
- `.claude/skills/<name>/SKILL.md`

### Codex-side discovery

Because Codex phases run with `-C "$PROJECT_PATH"`, Codex can auto-discover:

- `AGENTS.md`
- `.codex/config.toml`
- `.codex/agents/*.toml`
- `.agents/skills/<name>/SKILL.md`

The prompt templates also explicitly instruct both tools to use project-defined agents or skills when relevant, and to parallelize independent work via subagents.

## Repository Structure

Current repository layout:

```text
.
├── orchestrate.sh
├── config.env
├── CLAUDE.md
├── README.md
├── lib/
│   ├── logging.sh
│   ├── memory.sh
│   ├── phases.sh
│   ├── prompts.sh
│   └── utils.sh
├── tests/
│   └── run.sh
└── prompts/
    ├── build.md
    ├── commit.md
    ├── document.md
    ├── fix_and_retest.md
    ├── live.md
    ├── plan_system.md
    ├── plan_task.md
    ├── retest_after_live.md
    ├── review.md
    └── ...
```

### File Roles

- [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh): bootstrap, validation, session setup, phase sequencing, and finalization
- [`config.env`](/root/github/opusdex/config.env): default models, binary paths, retry limits, and behavior flags
- [`lib/utils.sh`](/root/github/opusdex/lib/utils.sh): general shell helpers
- [`lib/logging.sh`](/root/github/opusdex/lib/logging.sh): colored logging and phase banners
- [`lib/memory.sh`](/root/github/opusdex/lib/memory.sh): `.opusdex/` initialization and lesson merging
- [`lib/prompts.sh`](/root/github/opusdex/lib/prompts.sh): template loading and placeholder substitution
- [`lib/phases.sh`](/root/github/opusdex/lib/phases.sh): implementations of each orchestrator phase
- [`tests/run.sh`](/root/github/opusdex/tests/run.sh): regression checks for retry, resume, memory, and live-phase workflows
- [`prompts/*.md`](/root/github/opusdex/prompts): phase-specific instructions given to Claude or Codex
- [`CLAUDE.md`](/root/github/opusdex/CLAUDE.md): repository-level instructions for Claude when working on OpusDex itself

## Development Notes

### Shell Validation

The current shell scripts parse successfully with:

```bash
bash -n orchestrate.sh lib/*.sh
```

The regression suite runs with:

```bash
./tests/run.sh
```

### Git Ignore Behavior

The repository root currently ignores:

- `tasks/`
- `logs/`
- `*.tmp`
- `.codanna/`

Per-project `.opusdex/.gitignore` files are seeded automatically and currently ignore:

- `tasks/`
- `logs/`
- `*.tmp`

## Current Caveats

These are worth knowing if you plan to extend the orchestrator:

- The plan prompt mentions Context7 tool names `resolve-library-id` and `get-library-docs`, but the exact available MCP naming depends on the AI runtime environment rather than this repository.

## Summary

OpusDex is a lightweight orchestrator for running a disciplined AI-assisted development loop against an existing Git repository. Its design is intentionally simple: Bash for coordination, Markdown prompt templates for behavior, per-project disk state for traceability, and a small amount of structured memory to improve later sessions.
