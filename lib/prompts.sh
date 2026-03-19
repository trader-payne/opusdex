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

    # Inject context (todo.md for build, test_results.md for review/fix_and_retest)
    local context=""
    case "$phase" in
        build)
            [[ -f "$SESSION_TASK_DIR/todo.md" ]] && context="$(cat "$SESSION_TASK_DIR/todo.md")"
            ;;
        review)
            [[ -f "$SESSION_TASK_DIR/test_results.md" ]] && context="$(cat "$SESSION_TASK_DIR/test_results.md")"
            ;;
        fix_and_retest)
            [[ -f "$SESSION_TASK_DIR/test_results.md" ]] && context="$(cat "$SESSION_TASK_DIR/test_results.md")"
            ;;
        live)
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

    # Inject diff summary (--stat + --name-only, not the full diff)
    local diff=""
    if [[ -n "${BASELINE_COMMIT:-}" ]]; then
        local stat names
        stat="$(git -C "$PROJECT_PATH" diff --stat "$BASELINE_COMMIT" HEAD 2>/dev/null || true)"
        names="$(git -C "$PROJECT_PATH" diff --name-only "$BASELINE_COMMIT" HEAD 2>/dev/null || true)"
        if [[ -z "$stat" ]]; then
            stat="$(git -C "$PROJECT_PATH" diff --stat 2>/dev/null || true)"
            names="$(git -C "$PROJECT_PATH" diff --name-only 2>/dev/null || true)"
        fi
        diff="### Files changed"$'\n'"$names"$'\n\n'"### Diffstat"$'\n'"$stat"
    fi
    prompt="${prompt//\{\{DIFF\}\}/$diff}"

    # Inject baseline commit ref
    prompt="${prompt//\{\{BASELINE_COMMIT\}\}/${BASELINE_COMMIT:-HEAD~1}}"

    # Inject review round number
    prompt="${prompt//\{\{REVIEW_ROUND\}\}/${REVIEW_ROUND:-1}}"

    # Inject live attempt number
    prompt="${prompt//\{\{LIVE_ATTEMPT\}\}/${LIVE_ATTEMPT:-1}}"

    # Inject review feedback
    local review=""
    [[ -f "$SESSION_TASK_DIR/review.md" ]] && review="$(cat "$SESSION_TASK_DIR/review.md")"
    prompt="${prompt//\{\{REVIEW\}\}/$review}"

    # Write to temp file and return path
    write_prompt_to_tmpfile "$prompt"
}

# Build system prompt + task prompt for interactive plan phase.
# Prints two temp file paths (system, task) separated by newline.
build_plan_prompts() {
    local system_template="${OPUSDEX_DIR}/prompts/plan_system.md"
    local task_template="${OPUSDEX_DIR}/prompts/plan_task.md"

    [[ -f "$system_template" ]] || abort "Prompt template not found: $system_template"
    [[ -f "$task_template" ]] || abort "Prompt template not found: $task_template"

    local memory_block
    memory_block="$(read_memory)"

    local system_prompt task_prompt
    system_prompt="$(cat "$system_template")"
    task_prompt="$(cat "$task_template")"

    # Substitute placeholders in both
    for var in system_prompt task_prompt; do
        declare "$var"="${!var//\{\{MEMORY\}\}/$memory_block}"
        declare "$var"="${!var//\{\{TASK\}\}/$TASK_DESCRIPTION}"
        declare "$var"="${!var//\{\{PROJECT_PATH\}\}/$PROJECT_PATH}"
        declare "$var"="${!var//\{\{SESSION_TASK_DIR\}\}/$SESSION_TASK_DIR}"
    done

    local system_file task_file
    system_file="$(write_prompt_to_tmpfile "$system_prompt")"
    task_file="$(write_prompt_to_tmpfile "$task_prompt")"

    printf '%s\n%s' "$system_file" "$task_file"
}
