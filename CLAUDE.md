# OpusDex — AI Development Orchestrator

OpusDex is a bash-based orchestrator that coordinates Claude Code CLI and OpenAI Codex CLI through a structured 7-phase development workflow.

## Architecture

```
orchestrate.sh          → Main entry point, CLI arg parsing, phase sequencing
config.env              → Default configuration (models, paths, behavior flags)
lib/utils.sh            → Shell utilities (dirs, timestamps, prompts, confirmations)
lib/logging.sh          → Color-coded phase logging
lib/memory.sh           → Persistent lesson memory (read/write/merge), per-project data init
lib/prompts.sh          → Prompt template assembly with placeholder substitution
lib/phases.sh           → 7 phase functions (plan/implement/test/review/fix/document/commit)
prompts/*.md            → Phase prompt templates with {{PLACEHOLDER}} variables
```

### Per-Project Data

All session data lives in `$PROJECT_PATH/.opusdex/`:

```
myapp/.opusdex/
├── .gitignore          # ignores tasks/, logs/, *.tmp
├── memory/
│   ├── claude_lessons.md
│   ├── codex_lessons.md
│   └── shared_context.md
├── tasks/<session_id>/
├── builds/
│   └── build_log.md
└── logs/
```

Memory, sessions, and build logs are per-project. Code and prompt templates remain in the opusdex repo.

## Workflow Phases

1. **Plan** (Claude, interactive) — Discuss and refine approach with user, produce `todo.md`
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

## Project Agent & Skill Discovery

Spawned processes auto-discover agents and skills defined in the target project:

- **Claude phases** (plan, review) run with `cwd` set to `$PROJECT_PATH`, so Claude auto-discovers:
  - `.claude/agents/<name>/AGENT.md` — project-defined agents
  - `.claude/skills/<name>/SKILL.md` — project-defined skills/slash commands
  - `CLAUDE.md` — project instructions
- **Codex phases** (implement, test, fix, document, commit) run with `-C $PROJECT_PATH`, so Codex auto-discovers:
  - `.codex/agents/*.toml` — project-defined agents
  - `.agents/skills/<name>/SKILL.md` — project-defined skills
  - `AGENTS.md` — project instructions
  - `.codex/config.toml` — project-level config overrides

All prompts instruct the AI to delegate to project-defined agents/skills when they match the task.

## Conventions

- All lib files are sourced, not executed — they define functions only.
- Prompts use `{{PLACEHOLDER}}` syntax, substituted by `build_prompt` in `lib/prompts.sh`.
- Memory files use markdown with `### Rule:` headers for machine-parseable lesson extraction.
- Session artifacts go in `$PROJECT_PATH/.opusdex/tasks/<session_id>/` (gitignored).
- YOLO mode is always on: Claude uses `--dangerously-skip-permissions`, Codex uses `--yolo`.
