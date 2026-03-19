#!/usr/bin/env bash
set -euo pipefail

# ─── Bootstrap ───────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.env"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/logging.sh"
source "$SCRIPT_DIR/lib/memory.sh"
source "$SCRIPT_DIR/lib/prompts.sh"
source "$SCRIPT_DIR/lib/phases.sh"

# ─── CLI Argument Parsing ────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
Usage: orchestrate.sh <task> --project /path [options]

Task can be provided as:
  "task description"       Inline string
  --task-file FILE         Read task from a file (markdown, text, etc.)
  path/to/file.md          Positional arg that is an existing file is read automatically

Options:
  --project PATH         Target project directory (required)
  --task-file FILE       Read task description from a file
  --auto-plan            Skip plan confirmation prompt
  --auto-commit          Skip commit confirmation prompt
  --phase PHASE          Resume from a specific phase
                         (plan|build|review|live|document|commit)
  --auto-live            Skip live pass confirmation prompt
  --claude-model MODEL   Override Claude model (default: opus)
  --claude-effort LEVEL  Override Claude effort (default: high)
  --codex-model MODEL    Override Codex model (default: chatgpt-5.4)
  --codex-effort LEVEL   Override Codex effort (default: xhigh)
  --gemini-model MODEL   Override Gemini model (default: gemini-3.1-pro-preview)
  -h, --help             Show this help message
EOF
    exit 0
}

TASK_DESCRIPTION=""
TASK_FILE=""
PROJECT_PATH=""
START_PHASE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        --project)
            PROJECT_PATH="$2"; shift 2
            ;;
        --task-file)
            TASK_FILE="$2"; shift 2
            ;;
        --auto-plan)
            AUTO_PLAN=true; shift
            ;;
        --auto-commit)
            AUTO_COMMIT=true; shift
            ;;
        --auto-live)
            AUTO_LIVE=true; shift
            ;;
        --phase)
            START_PHASE="$2"; shift 2
            ;;
        --claude-model)
            CLAUDE_MODEL="$2"; shift 2
            ;;
        --claude-effort)
            CLAUDE_EFFORT="$2"; shift 2
            ;;
        --codex-model)
            CODEX_MODEL="$2"; shift 2
            ;;
        --codex-effort)
            CODEX_EFFORT="$2"; shift 2
            ;;
        --gemini-model)
            GEMINI_MODEL="$2"; shift 2
            ;;
        -*)
            abort "Unknown option: $1"
            ;;
        *)
            if [[ -z "$TASK_DESCRIPTION" ]]; then
                TASK_DESCRIPTION="$1"; shift
            else
                abort "Unexpected argument: $1"
            fi
            ;;
    esac
done

# ─── Resolve Task Description ───────────────────────────────────────────────

# --task-file takes priority
if [[ -n "$TASK_FILE" ]]; then
    [[ -f "$TASK_FILE" ]] || abort "Task file does not exist: $TASK_FILE"
    TASK_DESCRIPTION="$(cat "$TASK_FILE")"
# Positional arg that is an existing file → read it
elif [[ -n "$TASK_DESCRIPTION" && -f "$TASK_DESCRIPTION" ]]; then
    TASK_FILE="$TASK_DESCRIPTION"
    TASK_DESCRIPTION="$(cat "$TASK_FILE")"
fi

# ─── Validation ──────────────────────────────────────────────────────────────

[[ -z "$TASK_DESCRIPTION" ]] && abort "Task description is required (first argument or --task-file)"
[[ -z "$PROJECT_PATH" ]] && abort "--project is required"
[[ -d "$PROJECT_PATH" ]] || abort "Project directory does not exist: $PROJECT_PATH"

PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"  # Resolve to absolute path

require_command "$CLAUDE_BIN"
require_command "$CODEX_BIN"
require_command "$GEMINI_BIN"
require_command "jq"
require_command "git"

# Verify project is a git repo
git -C "$PROJECT_PATH" rev-parse --git-dir &>/dev/null || abort "Project is not a git repository: $PROJECT_PATH"

# ─── Session Setup ───────────────────────────────────────────────────────────

PROJECT_DATA_DIR="$PROJECT_PATH/.opusdex"

# Initialize per-project data directory structure
init_project_data_dir

SESSION_REUSED=false

if [[ -n "$START_PHASE" ]]; then
    # Resume: reuse the most recent session task dir so phase artifacts remain available.
    latest="$(find "$PROJECT_DATA_DIR/tasks" -mindepth 1 -maxdepth 1 -type d | sort -r | head -1)"
    if [[ -n "$latest" ]]; then
        SESSION_TASK_DIR="$latest"
        SESSION_ID="$(basename "$SESSION_TASK_DIR")"
        SESSION_REUSED=true
    else
        SESSION_ID="$(datestamp)"
        SESSION_TASK_DIR="$PROJECT_DATA_DIR/tasks/$SESSION_ID"
    fi
else
    SESSION_ID="$(datestamp)"
    SESSION_TASK_DIR="$PROJECT_DATA_DIR/tasks/$SESSION_ID"
fi

ensure_dir "$SESSION_TASK_DIR"

BASELINE_COMMIT="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
SESSION_START=$(date +%s)

# Initialize memory files
init_memory_files

# ─── Logging Setup ───────────────────────────────────────────────────────────

LOG_FILE="$PROJECT_DATA_DIR/logs/session_${SESSION_ID}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Session Banner ──────────────────────────────────────────────────────────

log_separator
printf "${CLR_BOLD}  OpusDex Orchestrator${CLR_RESET}\n"
log_separator
log_info "Session:  $SESSION_ID"
log_info "Task:     $TASK_DESCRIPTION"
log_info "Project:  $PROJECT_PATH"
log_info "Baseline: $BASELINE_COMMIT"
log_info "Claude:   $CLAUDE_MODEL (effort: $CLAUDE_EFFORT)"
log_info "Codex:    $CODEX_MODEL (effort: $CODEX_EFFORT)"
log_info "Gemini:   $GEMINI_MODEL"
log_info "Auto-plan: $AUTO_PLAN"
log_info "Auto-live: $AUTO_LIVE"
log_info "Auto-commit: $AUTO_COMMIT"
[[ "$SESSION_REUSED" == true ]] && log_info "Resuming session: $SESSION_ID"
[[ -n "$START_PHASE" ]] && log_info "Resuming from: $START_PHASE"
echo ""

# Save task description to session dir for reference
printf '%s\n' "$TASK_DESCRIPTION" > "$SESSION_TASK_DIR/task.txt"

# ─── Phase Execution ─────────────────────────────────────────────────────────

PHASES=(plan build review live document commit)

# Backward-compat: map old phase names
case "${START_PHASE:-}" in
    implement|test) START_PHASE="build" ;;
    fix)            START_PHASE="review" ;;
    live_pass)      START_PHASE="live" ;;
esac

SKIP=true
if [[ -z "$START_PHASE" ]]; then
    SKIP=false
fi

# Try to recover Claude session ID from a previous plan phase in this session dir
if [[ -f "$SESSION_TASK_DIR/claude_session_id" ]]; then
    CLAUDE_SESSION_ID="$(cat "$SESSION_TASK_DIR/claude_session_id")"
    log_info "Recovered Claude session: $CLAUDE_SESSION_ID"
fi

run_phase() {
    local phase="$1"

    if [[ "$SKIP" == true ]]; then
        if [[ "$phase" == "$START_PHASE" ]]; then
            SKIP=false
        else
            log_info "Skipping phase: $phase"
            return 0
        fi
    fi

    case "$phase" in
        plan)
            phase_plan || abort "Plan phase failed"
            ;;
        build)
            phase_build || abort "Build phase failed"
            ;;
        review)
            phase_review_and_live || abort "Review/live cycle failed"
            LIVE_DONE=true  # live was handled inside review+live cycle
            ;;
        live)
            # Only run standalone when explicitly resumed via --phase live
            if [[ "${LIVE_DONE:-}" != "true" ]]; then
                phase_live_inner || abort "Live pass failed"
            fi
            ;;
        document)
            phase_document || abort "Document phase failed"
            ;;
        commit)
            phase_commit || abort "Commit phase failed"
            ;;
    esac
}

for phase in "${PHASES[@]}"; do
    run_phase "$phase"
done

# ─── Finalize ────────────────────────────────────────────────────────────────

generate_session_summary() {
    local summary_context=""

    # Gather available session artifacts
    if [[ -f "$SESSION_TASK_DIR/todo.md" ]]; then
        summary_context+="## Plan"$'\n'"$(cat "$SESSION_TASK_DIR/todo.md")"$'\n\n'
    fi
    if [[ -f "$SESSION_TASK_DIR/review.md" ]]; then
        summary_context+="## Review"$'\n'"$(cat "$SESSION_TASK_DIR/review.md")"$'\n\n'
    fi
    if [[ -f "$SESSION_TASK_DIR/test_results.md" ]]; then
        summary_context+="## Test Results"$'\n'"$(cat "$SESSION_TASK_DIR/test_results.md")"$'\n\n'
    fi

    local diff_stat
    diff_stat="$(git -C "$PROJECT_PATH" diff --stat "$BASELINE_COMMIT" HEAD 2>/dev/null || true)"
    if [[ -n "$diff_stat" ]]; then
        summary_context+="## Diff Stat"$'\n'"$diff_stat"$'\n\n'
    fi

    # Fall back to raw task if no artifacts exist
    if [[ -z "$summary_context" ]]; then
        echo "$TASK_DESCRIPTION"
        return
    fi

    local prompt="Summarize this development session in 2-4 sentences. Focus on what was implemented or changed, key decisions made, and the final outcome (tests passing, review approved, etc.). Be specific and concise — this is for a build log."
    prompt+=$'\n\n'"## Original Task"$'\n'"$TASK_DESCRIPTION"$'\n\n'"$summary_context"

    local result
    result="$("$CLAUDE_BIN" --print -p "$prompt" --model haiku --output-format text 2>/dev/null)" || true

    if [[ -n "$result" ]]; then
        echo "$result"
    else
        echo "$TASK_DESCRIPTION"
    fi
}

finalize_session() {
    local status="${1:-SUCCESS}"

    log_separator
    printf "${CLR_BOLD}  Finalizing Session${CLR_RESET}\n"
    log_separator

    # Merge lessons into persistent memory
    merge_session_lessons "$SESSION_TASK_DIR"

    # Gather commit info and session summary
    local commit_hash commit_msg duration summary
    commit_hash="$(git -C "$PROJECT_PATH" log -1 --format='%h' 2>/dev/null || echo 'none')"
    commit_msg="$(git -C "$PROJECT_PATH" log -1 --format='%s' 2>/dev/null || echo 'none')"
    duration="$(duration_since "$SESSION_START")"

    log_info "Generating session summary..."
    summary="$(generate_session_summary)"

    # Write build log entry
    cat >> "$PROJECT_DATA_DIR/builds/build_log.md" <<EOF

## $(date '+%Y-%m-%d %H:%M') | $SESSION_ID
**Task**: $TASK_DESCRIPTION
**Summary**:
$summary
**Status**: $status
**Commit**: \`$commit_hash\` — $commit_msg
**Duration**: $duration
---
EOF

    log_success "Session $SESSION_ID completed ($status) in $duration"
    log_info "Build log updated: $PROJECT_DATA_DIR/builds/build_log.md"
    log_info "Session artifacts: $SESSION_TASK_DIR"
}

finalize_session "SUCCESS"
