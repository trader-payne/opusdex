#!/usr/bin/env bash
# OpusDex memory management

init_project_data_dir() {
    ensure_dir "$PROJECT_DATA_DIR"
    ensure_dir "$PROJECT_DATA_DIR/memory"
    ensure_dir "$PROJECT_DATA_DIR/tasks"
    ensure_dir "$PROJECT_DATA_DIR/builds"
    ensure_dir "$PROJECT_DATA_DIR/logs"

    # Create .gitignore if it doesn't exist
    if [[ ! -f "$PROJECT_DATA_DIR/.gitignore" ]]; then
        cat > "$PROJECT_DATA_DIR/.gitignore" <<'EOF'
tasks/
logs/
*.tmp
EOF
    fi

    # Seed build log if it doesn't exist
    if [[ ! -f "$PROJECT_DATA_DIR/builds/build_log.md" ]]; then
        cat > "$PROJECT_DATA_DIR/builds/build_log.md" <<'EOF'
# OpusDex Build Log
EOF
    fi
}

init_memory_files() {
    local memory_dir="${PROJECT_DATA_DIR}/memory"
    ensure_dir "$memory_dir"

    if [[ ! -f "$memory_dir/shared_context.md" ]]; then
        cat > "$memory_dir/shared_context.md" <<'EOF'
# Shared Context
> Project knowledge shared between Claude Code and Codex.
EOF
    fi
}

read_memory() {
    local memory_dir="${PROJECT_DATA_DIR}/memory"
    local output=""

    if [[ -f "$memory_dir/shared_context.md" ]]; then
        output="$(cat "$memory_dir/shared_context.md")"
    fi

    printf '%s' "$output"
}

# AI-curated memory merge: sends existing memory + new lessons to Claude,
# which returns a consolidated, pruned version. Falls back to blind append
# if the Claude call fails.
curate_memory() {
    local existing_memory="$1"
    local new_lessons="$2"

    local prompt
    prompt="$(cat <<'PROMPT_EOF'
You are a memory curator for an AI development orchestrator. You maintain a shared context file that is injected into every AI prompt — so brevity matters.

You will receive the current shared context (existing rules) and new lessons from the latest session. Produce an updated shared context file that:

1. **Integrates** genuinely new, specific, actionable insights from the new lessons
2. **Merges** rules that cover the same topic into a single consolidated rule
3. **Drops** rules that are vague, trivially obvious, or superseded by newer rules
4. **Preserves** the format: each rule starts with `### Rule:` followed by `- **Why**:` and `- **How to apply**:` lines
5. **Keeps** the file header (`# Shared Context` + description line) intact
6. **Stays under 50 rules total** — if over, prioritize the most specific and actionable ones

Output the complete updated file. No commentary, no explanations — just the file content.
PROMPT_EOF
)"

    prompt+=$'\n\n'"## Current Shared Context"$'\n'"$existing_memory"
    prompt+=$'\n\n'"## New Lessons from This Session"$'\n'"$new_lessons"

    local result
    result="$("$CLAUDE_BIN" --print -p "$prompt" --model haiku --output-format text 2>/dev/null)" || true

    # Validate the result looks like a proper shared context file
    if [[ -n "$result" ]] && echo "$result" | grep -q "^# Shared Context"; then
        printf '%s' "$result"
    fi
}

# Fallback: blind append with header-level dedup (used when AI curation fails)
merge_lessons_fallback() {
    local lessons_file="$1"
    local shared_file="$2"

    local added=0
    local current_rule=""
    local current_block=""
    local in_rule=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^###\ Rule: ]]; then
            if [[ "$in_rule" == true && -n "$current_block" ]]; then
                if ! grep -qF "$current_rule" "$shared_file" 2>/dev/null; then
                    printf '\n%s' "$current_block" >> "$shared_file"
                    added=$((added + 1))
                fi
            fi
            current_rule="$line"
            current_block="$line"
            in_rule=true
        elif [[ "$in_rule" == true ]]; then
            current_block+=$'\n'"$line"
        fi
    done < "$lessons_file"

    if [[ "$in_rule" == true && -n "$current_block" ]]; then
        if ! grep -qF "$current_rule" "$shared_file" 2>/dev/null; then
            printf '\n%s' "$current_block" >> "$shared_file"
            added=$((added + 1))
        fi
    fi

    log_info "Fallback merge: appended $added new lesson(s)"
}

merge_session_lessons() {
    local session_dir="$1"
    local lessons_file="$session_dir/lessons.md"

    if [[ ! -f "$lessons_file" ]]; then
        log_info "No lessons found in session"
        return 0
    fi

    local memory_dir="${PROJECT_DATA_DIR}/memory"
    local shared_file="$memory_dir/shared_context.md"

    local existing_memory=""
    if [[ -f "$shared_file" ]]; then
        existing_memory="$(cat "$shared_file")"
    fi

    local new_lessons
    new_lessons="$(cat "$lessons_file")"

    # Check if there are any rule blocks in the lessons
    if ! echo "$new_lessons" | grep -q "^### Rule:"; then
        log_info "No new rules found in lessons"
        return 0
    fi

    log_info "Curating shared context with new lessons..."
    local curated
    curated="$(curate_memory "$existing_memory" "$new_lessons")"

    if [[ -n "$curated" ]]; then
        printf '%s\n' "$curated" > "$shared_file"
        log_success "Shared context curated and updated"
    else
        log_warn "AI curation failed — falling back to blind merge"
        merge_lessons_fallback "$lessons_file" "$shared_file"
    fi
}
