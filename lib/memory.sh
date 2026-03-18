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

merge_session_lessons() {
    local session_dir="$1"
    local lessons_file="$session_dir/lessons.md"

    if [[ ! -f "$lessons_file" ]]; then
        log_info "No lessons found in session"
        return 0
    fi

    local memory_dir="${PROJECT_DATA_DIR}/memory"
    local shared_file="$memory_dir/shared_context.md"

    # Extract rules from lessons file (lines starting with ### Rule:)
    local new_rules=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^###\ Rule:\ (.+) ]]; then
            new_rules+=("${BASH_REMATCH[1]}")
        fi
    done < "$lessons_file"

    if [[ ${#new_rules[@]} -eq 0 ]]; then
        log_info "No new rules found in lessons"
        return 0
    fi

    local existing_content=""
    if [[ -f "$shared_file" ]]; then
        existing_content="$(cat "$shared_file")"
    fi

    local added=0
    local current_rule=""
    local current_block=""
    local in_rule=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^###\ Rule: ]]; then
            # Save previous rule block if any
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

    # Handle last rule block
    if [[ "$in_rule" == true && -n "$current_block" ]]; then
        if ! grep -qF "$current_rule" "$shared_file" 2>/dev/null; then
            printf '\n%s' "$current_block" >> "$shared_file"
            added=$((added + 1))
        fi
    fi

    log_success "Merged $added new lesson(s) into shared context"
}
