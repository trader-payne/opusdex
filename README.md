# OpusDex

OpusDex is a Bash-based AI development orchestrator. It runs a target Git repository through a structured workflow that combines Claude Code CLI for planning and review with OpenAI Codex CLI for implementation, testing, documentation, and commit creation.

The orchestrator itself lives in this repository. Session state, memory, logs, and build history are written into the target project under `.opusdex/`, so each project keeps its own execution history.

## What It Does

- Starts from a task description and a target project path.
- Creates a per-project working area for plans, outputs, logs, memory, and build history.
- Runs a repeatable phase pipeline across two AI CLIs.
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
2. `implement`
3. `test`
4. `review`
5. `document`
6. `commit`

There is also a `fix` phase implemented in [`lib/phases.sh`](/root/github/opusdex/lib/phases.sh), but it is invoked internally during retry loops rather than as part of the normal top-level phase list.

### Phase Responsibilities

| Phase | Tool | Mode | Main purpose | Expected session artifact |
| --- | --- | --- | --- | --- |
| Plan | Claude Code CLI | Interactive | Explore the target repo with the user and write an implementation plan | `todo.md` |
| Implement | Codex CLI | Non-interactive exec | Apply the agreed plan | `implement_output.md` |
| Test | Codex CLI | Non-interactive exec | Run and/or add tests, then summarize results | `test_output.md`, `test_results.md` |
| Review | Claude Code CLI | Non-interactive JSON output | Review the diff and produce a verdict | `review_output.json`, `review.md` |
| Fix | Codex CLI | Non-interactive exec | Address failed tests or review feedback | `fix_output.md` |
| Document | Codex CLI | Non-interactive exec | Update documentation or comments | `document_output.md` |
| Commit | Codex CLI | Non-interactive exec | Stage relevant files and create a local commit | `commit_output.md` |

### Retry and Gating Behavior

- `test` is wrapped by `phase_test_with_retries`, which retries up to `TEST_RETRY_LIMIT`.
- If a test attempt fails and retries remain, OpusDex runs `fix` before retrying.
- `review` is wrapped by `phase_review_with_gate`.
- If review returns `REQUEST_CHANGES` or `BLOCK` and retries remain, OpusDex runs `fix`, then reruns testing, then reviews again.
- `commit` is gated by a confirmation prompt unless `--auto-commit` is used.

## Requirements

OpusDex assumes a Unix-like environment with standard shell utilities. Based on the current code, you should have:

- Bash 4+.
- `git`
- `jq`
- Claude Code CLI
- OpenAI Codex CLI
- Standard utilities such as `cat`, `date`, `grep`, `head`, `mktemp`, `sed`, `seq`, `tail`, `tee`, and `tr`

The target project must already be a Git repository.

## Installation and Setup

There is no installer script in this repository. Setup is manual:

1. Clone this repository.
2. Review and edit [`config.env`](/root/github/opusdex/config.env).
3. Make sure the configured Claude and Codex CLI binaries exist and are authenticated.
4. Run [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh) against a target project.

The current default configuration is:

| Setting | Default |
| --- | --- |
| `CLAUDE_MODEL` | `opus` |
| `CLAUDE_EFFORT` | `high` |
| `CODEX_MODEL` | `gpt-5.4` |
| `CODEX_EFFORT` | `xhigh` |
| `AUTO_COMMIT` | `false` |
| `TEST_RETRY_LIMIT` | `3` |
| `REVIEW_RETRY_LIMIT` | `1` |
| `CODEX_YOLO_FLAG` | `--yolo` |

Default binary paths are also defined in [`config.env`](/root/github/opusdex/config.env):

- `CLAUDE_BIN="/root/.local/bin/claude"`
- `CODEX_BIN="/root/.nvm/versions/node/v25.8.1/bin/codex"`

## Usage

```bash
./orchestrate.sh "task description" --project /path/to/project [options]
```

### CLI Options

| Option | Meaning |
| --- | --- |
| `--project PATH` | Target project directory. Required. |
| `--auto-commit` | Skip the interactive commit confirmation prompt. |
| `--phase PHASE` | Resume from a specific phase. Earlier phases are skipped. |
| `--claude-model MODEL` | Override the Claude model for this run. |
| `--claude-effort LEVEL` | Override Claude reasoning effort. |
| `--codex-model MODEL` | Override the Codex model for this run. |
| `--codex-effort LEVEL` | Override Codex reasoning effort. |
| `-h`, `--help` | Show usage text. |

### Example Commands

Run a full session:

```bash
./orchestrate.sh "Add CSV import support" --project /root/src/myapp
```

Resume from testing after an interrupted run:

```bash
./orchestrate.sh "Add CSV import support" --project /root/src/myapp --phase test
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
4. Passes the prompt text to Claude or Codex.

Plan is special: it uses separate system and task prompts from [`prompts/plan_system.md`](/root/github/opusdex/prompts/plan_system.md) and [`prompts/plan_task.md`](/root/github/opusdex/prompts/plan_task.md).

The current placeholder sources are:

| Placeholder | Source |
| --- | --- |
| `{{MEMORY}}` | Output of `read_memory()` |
| `{{TASK}}` | Task description passed on the command line |
| `{{PROJECT_PATH}}` | Absolute target project path |
| `{{SESSION_TASK_DIR}}` | Session artifact directory |
| `{{CONTEXT}}` | `todo.md` for `implement`; `test_results.md` for `review` and `fix` |
| `{{CHANGES}}` | `git diff --name-only` from baseline to `HEAD`, with working-tree fallback |
| `{{DIFF}}` | Full `git diff` from baseline to `HEAD`, with working-tree fallback |
| `{{REVIEW}}` | Contents of `review.md`, if present |

### Memory Model

Memory management lives in [`lib/memory.sh`](/root/github/opusdex/lib/memory.sh).

Each target project gets a shared memory file — `memory/shared_context.md` — injected into every prompt via `{{MEMORY}}`.

At session finalization, OpusDex looks for `lessons.md` in the session directory. Any sections beginning with `### Rule:` are appended to `shared_context.md` if they are not already present.

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
        ├── implement_output.md
        ├── test_output.md
        ├── test_results.md
        ├── review_output.json
        ├── review.md
        ├── fix_output.md
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
- final status
- latest commit hash and subject line
- files changed between the baseline commit and `HEAD`
- session duration

## AI Tool Integration

### Claude Usage

Claude is used for:

- interactive planning
- review

Current execution behavior:

- plan runs from the target project directory
- review runs from the target project directory
- both Claude invocations use `--dangerously-skip-permissions`

### Codex Usage

Codex is used for:

- implement
- test
- fix
- document
- commit

Current execution behavior:

- every Codex phase uses `codex exec`
- every Codex phase runs with `-C "$PROJECT_PATH"`
- every Codex phase passes the configured reasoning effort
- every Codex phase uses the configured YOLO flag, which defaults to `--yolo`

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
└── prompts/
    ├── commit.md
    ├── document.md
    ├── fix.md
    ├── implement.md
    ├── plan_system.md
    ├── plan_task.md
    ├── review.md
    └── test.md
```

### File Roles

- [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh): bootstrap, validation, session setup, phase sequencing, and finalization
- [`config.env`](/root/github/opusdex/config.env): default models, binary paths, retry limits, and behavior flags
- [`lib/utils.sh`](/root/github/opusdex/lib/utils.sh): general shell helpers
- [`lib/logging.sh`](/root/github/opusdex/lib/logging.sh): colored logging and phase banners
- [`lib/memory.sh`](/root/github/opusdex/lib/memory.sh): `.opusdex/` initialization and lesson merging
- [`lib/prompts.sh`](/root/github/opusdex/lib/prompts.sh): template loading and placeholder substitution
- [`lib/phases.sh`](/root/github/opusdex/lib/phases.sh): implementations of each orchestrator phase
- [`prompts/*.md`](/root/github/opusdex/prompts): phase-specific instructions given to Claude or Codex
- [`CLAUDE.md`](/root/github/opusdex/CLAUDE.md): repository-level instructions for Claude when working on OpusDex itself

## Development Notes

### Shell Validation

The current shell scripts parse successfully with:

```bash
bash -n orchestrate.sh lib/*.sh
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

- The CLI help text lists `fix` as a valid `--phase` resume target, but the top-level `PHASES` array in [`orchestrate.sh`](/root/github/opusdex/orchestrate.sh) does not include it. In current code, `fix` runs only inside retry flows.
- The CLI help text says the default Codex model is `chatgpt-5.4`, while [`config.env`](/root/github/opusdex/config.env) currently sets `CODEX_MODEL="gpt-5.4"`.
- [`config.env`](/root/github/opusdex/config.env) says values are overridable by environment variables, but current assignments are unconditional. In practice, CLI flags and direct edits to `config.env` are the reliable override mechanisms.
- The plan prompt mentions Context7 tool names `resolve-library-id` and `get-library-docs`, but the exact available MCP naming depends on the AI runtime environment rather than this repository.

## Summary

OpusDex is a lightweight orchestrator for running a disciplined AI-assisted development loop against an existing Git repository. Its design is intentionally simple: Bash for coordination, Markdown prompt templates for behavior, per-project disk state for traceability, and a small amount of structured memory to improve later sessions.
