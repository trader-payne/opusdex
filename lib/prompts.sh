#!/usr/bin/env bash
# OpusDex prompt template assembly

build_prompt() {
    local phase="$1"
    local template_file="${OPUSDEX_DIR}/prompts/${phase}.md"

    if [[ ! -f "$template_file" ]]; then
        abort "Prompt template not found: $template_file"
    fi

    local prompt
    prompt="$(cat "$template_file")"

    # Inject memory
    local memory_block
    memory_block="$(read_memory)"
    prompt="${prompt//\{\{MEMORY\}\}/$memory_block}"

    # Inject task description
    prompt="${prompt//\{\{TASK\}\}/$TASK_DESCRIPTION}"

    # Inject project path
    prompt="${prompt//\{\{PROJECT_PATH\}\}/$PROJECT_PATH}"

    # Inject session task dir
    prompt="${prompt//\{\{SESSION_TASK_DIR\}\}/$SESSION_TASK_DIR}"

    # Inject context (todo.md for implement/fix, test_results.md for review)
    local context=""
    case "$phase" in
        implement)
            [[ -f "$SESSION_TASK_DIR/todo.md" ]] && context="$(cat "$SESSION_TASK_DIR/todo.md")"
            ;;
        review)
            [[ -f "$SESSION_TASK_DIR/test_results.md" ]] && context="$(cat "$SESSION_TASK_DIR/test_results.md")"
            ;;
        fix)
            [[ -f "$SESSION_TASK_DIR/test_results.md" ]] && context="$(cat "$SESSION_TASK_DIR/test_results.md")"
            ;;
    esac
    prompt="${prompt//\{\{CONTEXT\}\}/$context}"

    # Inject changes (git diff --name-only from baseline)
    local changes=""
    if [[ -n "${BASELINE_COMMIT:-}" ]]; then
        changes="$(git -C "$PROJECT_PATH" diff --name-only "$BASELINE_COMMIT" HEAD 2>/dev/null || true)"
        if [[ -z "$changes" ]]; then
            changes="$(git -C "$PROJECT_PATH" diff --name-only 2>/dev/null || true)"
        fi
    fi
    prompt="${prompt//\{\{CHANGES\}\}/$changes}"

    # Inject diff
    local diff=""
    if [[ -n "${BASELINE_COMMIT:-}" ]]; then
        diff="$(git -C "$PROJECT_PATH" diff "$BASELINE_COMMIT" HEAD 2>/dev/null || true)"
        if [[ -z "$diff" ]]; then
            diff="$(git -C "$PROJECT_PATH" diff 2>/dev/null || true)"
        fi
    fi
    prompt="${prompt//\{\{DIFF\}\}/$diff}"

    # Inject review feedback
    local review=""
    [[ -f "$SESSION_TASK_DIR/review.md" ]] && review="$(cat "$SESSION_TASK_DIR/review.md")"
    prompt="${prompt//\{\{REVIEW\}\}/$review}"

    # Write to temp file and return path
    write_prompt_to_tmpfile "$prompt"
}
