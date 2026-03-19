# OpusDex — AI Development Orchestrator

OpusDex is a bash-based orchestrator that coordinates Claude Code CLI, OpenAI Codex CLI, and optionally Gemini CLI through a structured development workflow.

## Architecture

```
orchestrate.sh          → Main entry point, CLI arg parsing, phase sequencing
config.env              → Default configuration (models, paths, behavior flags)
lib/utils.sh            → Shell utilities (dirs, timestamps, prompts, confirmations)
lib/logging.sh          → Color-coded phase logging
lib/memory.sh           → Persistent lesson memory (read/write/merge), per-project data init
lib/prompts.sh          → Prompt template assembly with placeholder substitution
lib/phases.sh           → Phase functions (plan/build/review/live/document/commit)
prompts/*.md            → Phase prompt templates with {{PLACEHOLDER}} variables
```

### Per-Project Data

All session data lives in `$PROJECT_PATH/.opusdex/`:

```
myapp/.opusdex/
├── .gitignore          # ignores tasks/, logs/, *.tmp
├── memory/
│   └── shared_context.md
├── tasks/<session_id>/
├── builds/
│   └── build_log.md
└── logs/
```

Memory, sessions, and build logs are per-project. Code and prompt templates remain in the opusdex repo.

## Workflow Phases

1. **Plan** (Claude, interactive) — Discuss and refine approach with user, produce `todo.md`
2. **Build** (Codex, single session) — Implement the plan + run/write tests + fix failures, all in one `codex exec` call so Codex retains full implementation context during testing
3. **Review & Live Validation** (Claude + Gemini) — Code review with verdict (APPROVE/REQUEST_CHANGES/BLOCK). Uses `--resume` to continue the plan conversation.
   - If REQUEST_CHANGES/BLOCK → **Fix & Retest** (Codex, single session) — fix + retest in one call → re-review
   - **Live Pass** (Gemini, optional) — Validates the app in a live environment. If it fails, Gemini can retry fixes. If Gemini exhausts retries, it outputs `live_feedback.md`, and Claude re-reviews to design a fix. If Gemini successfully fixes issues, Codex runs a **Post-Live Verify** test pass before the loop continues.
4. **Document** (Codex, write) — Update documentation
5. **Commit** (Codex, write) — Stage and commit (gated on approval)

### Session Continuity

```
Claude session:  plan ──────────────────────► review ──────► re-review (with live_feedback.md)
                   │                            ▲  │            ▲
                   │  (file handoff)            │  │            │
                   ▼                            │  ▼            │
Codex session:   build (impl+test) ─────────────┘  fix+retest──┘
                                                                ▲
Gemini session:                                                 │
(Live env pass)─────────────────────────────────────────► live+fix (returns code 0, 1, or 2)
```

- **Claude**: plan and review share a conversation via `--session-id` / `--resume`. The review phase has full context from planning (codebase exploration, architecture understanding). Review history and live feedback accumulate in `review.md` and `live_feedback.md`.
- **Codex**: build = implement + test + inline fix in one `codex exec` call. Fix & retest = fix + test in one call. Post-live verify = test in one call. Each retains full context within its session.
- **Gemini**: live = test + fix in an interactive prompt via `gemini -m ...`.
- **Handoff**: file-based (`todo.md`, `test_results.md`, `review.md`, `live_feedback.md`, `live_results.md`) at tool boundaries.

## Running

```bash
./orchestrate.sh "task description" --project /path/to/project [--auto-plan] [--auto-live] [--auto-commit] [--phase PHASE]
```

## Project Agent & Skill Discovery

Spawned processes auto-discover agents and skills defined in the target project:

- **Claude phases** (plan, review) run with `cwd` set to `$PROJECT_PATH`, so Claude auto-discovers:
  - `.claude/agents/<name>/AGENT.md` — project-defined agents
  - `.claude/skills/<name>/SKILL.md` — project-defined skills/slash commands
  - `CLAUDE.md` — project instructions
- **Codex phases** (build, fix, document, commit) run with `-C $PROJECT_PATH`, so Codex auto-discovers:
  - `.codex/agents/*.toml` — project-defined agents
  - `.agents/skills/<name>/SKILL.md` — project-defined skills
  - `AGENTS.md` — project instructions
  - `.codex/config.toml` — project-level config overrides

All prompts instruct the AI to delegate to project-defined agents/skills when they match the task.

## MCP Integrations

All phase prompts instruct the AI to use these MCPs when the tools are available:

- **Context7** — external library docs. `resolve-library-id` → `get-library-docs`.
- **Codanna** — code intelligence (symbols, relationships, impact analysis) + document search. Supports: Rust, Python, TypeScript, JavaScript, Java, Kotlin, Go, PHP, C, C++, C#, Swift, GDScript. Requires `codanna init && codanna index .` for code, and `codanna documents index` for docs. Document collections are configured in `.codanna/settings.toml` (`[documents]` section).
- **Claude Context** — semantic code + documentation search (hybrid BM25 + vector). Indexes both code and markdown/docs (`.md`, `.markdown`, `.ipynb`) by default. Supports: TypeScript, JavaScript, Python, Java, C++, C#, Go, Rust, PHP, Ruby, Swift, Kotlin, Scala. Requires OpenAI API key + Zilliz Cloud. Async indexing — `search_code` returns partial results while indexing.

Each phase prompt lists which specific tools to use and when (e.g., `analyze_impact` during planning for risk assessment, `search_documents` to check project docs for conventions, `search_code` to find both code and documentation). Prompts say "skip any that aren't present" so phases work fine without the MCPs configured.

## Conventions

- All lib files are sourced, not executed — they define functions only.
- Prompts use `{{PLACEHOLDER}}` syntax, substituted by `build_prompt` in `lib/prompts.sh`.
- Memory files use markdown with `### Rule:` headers for machine-parseable lesson extraction.
- Session artifacts go in `$PROJECT_PATH/.opusdex/tasks/<session_id>/` (gitignored).
- YOLO mode is always on: Claude uses `--dangerously-skip-permissions`, Codex and Gemini use `--yolo`.
