# OpusDex — AI Development Orchestrator

OpusDex is a bash-based orchestrator that coordinates Claude Code CLI and OpenAI Codex CLI through a structured 7-phase development workflow.

## Architecture

```
orchestrate.sh          → Main entry point, CLI arg parsing, phase sequencing
config.env              → Default configuration (models, paths, behavior flags)
lib/utils.sh            → Shell utilities (dirs, timestamps, prompts, confirmations)
lib/logging.sh          → Color-coded phase logging
lib/memory.sh           → Persistent lesson memory (read/write/merge)
lib/prompts.sh          → Prompt template assembly with placeholder substitution
lib/phases.sh           → 7 phase functions (plan/implement/test/review/fix/document/commit)
prompts/*.md            → Phase prompt templates with {{PLACEHOLDER}} variables
memory/*.md             → Persistent lessons and shared context across sessions
builds/build_log.md     → History of completed development cycles
```

## Workflow Phases

1. **Plan** (Claude, read-only) — Analyze task, produce `todo.md`
2. **Implement** (Codex, write) — Execute the plan
3. **Test** (Codex, write) — Run and write tests, retry up to TEST_RETRY_LIMIT
4. **Review** (Claude, read-only) — Code review with verdict (APPROVE/REQUEST_CHANGES/BLOCK)
5. **Fix** (Codex, write) — Address review feedback (if needed)
6. **Document** (Codex, write) — Update documentation
7. **Commit** (Codex, write) — Stage and commit (gated on approval)

## Running

```bash
./orchestrate.sh "task description" --project /path/to/project [--auto-commit] [--phase PHASE]
```

## Conventions

- All lib files are sourced, not executed — they define functions only.
- Prompts use `{{PLACEHOLDER}}` syntax, substituted by `build_prompt` in `lib/prompts.sh`.
- Memory files use markdown with `### Rule:` headers for machine-parseable lesson extraction.
- Session artifacts go in `tasks/<session_id>/` (gitignored).
- YOLO mode is always on: Claude uses `--dangerously-skip-permissions`, Codex uses `--yolo`.
