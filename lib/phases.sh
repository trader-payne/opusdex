#!/usr/bin/env bash
# OpusDex phase execution functions

# ─── Plan (Claude, interactive) ──────────────────────────────────────────────

phase_plan() {
    log_phase "plan"

    local prompt_files system_prompt_file task_prompt_file
    prompt_files="$(build_plan_prompts)"
    system_prompt_file="$(echo "$prompt_files" | head -1)"
    task_prompt_file="$(echo "$prompt_files" | tail -1)"

    log_info "Starting interactive planning session with Claude..."
    log_info "Discuss the plan, then Claude will write todo.md. Exit with /exit or Ctrl+C when done."
    echo ""

    # Run from project dir so Claude auto-discovers .claude/agents/, .claude/skills/, CLAUDE.md
    (cd "$PROJECT_PATH" && "$CLAUDE_BIN" \
        --model "$CLAUDE_MODEL" \
        --effort "$CLAUDE_EFFORT" \
        --dangerously-skip-permissions \
        --system-prompt "$(cat "$system_prompt_file")" \
        -p "$(cat "$task_prompt_file")") || true

    rm -f "$system_prompt_file" "$task_prompt_file"

    # Verify todo.md was produced
    if [[ ! -f "$SESSION_TASK_DIR/todo.md" ]]; then
        log_error "todo.md was not created during planning session"
        log_info "Re-run with --phase plan to try again"
        return 1
    fi

    log_success "Planning complete — see $SESSION_TASK_DIR/todo.md"
    return 0
}

# ─── Implement (Codex, write) ────────────────────────────────────────────────

phase_implement() {
    log_phase "implement"

    local prompt_file
    prompt_file="$(build_prompt "implement")"

    log_info "Invoking Codex for implementation..."

    local output_file="$SESSION_TASK_DIR/implement_output.md"

    "$CODEX_BIN" exec \
        -m "$CODEX_MODEL" \
        -c model_reasoning_effort="$CODEX_EFFORT" \
        $CODEX_YOLO_FLAG \
        -C "$PROJECT_PATH" \
        -o "$output_file" \
        "$(cat "$prompt_file")" \
        2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Codex implementation failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    log_success "Implementation complete"
    return 0
}

# ─── Test (Codex, write) ─────────────────────────────────────────────────────

phase_test() {
    log_phase "test"

    local prompt_file
    prompt_file="$(build_prompt "test")"

    log_info "Invoking Codex for testing..."

    local output_file="$SESSION_TASK_DIR/test_output.md"

    "$CODEX_BIN" exec \
        -m "$CODEX_MODEL" \
        -c model_reasoning_effort="$CODEX_EFFORT" \
        $CODEX_YOLO_FLAG \
        -C "$PROJECT_PATH" \
        -o "$output_file" \
        "$(cat "$prompt_file")" \
        2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Codex testing failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    # Check verdict in test_results.md
    if [[ -f "$SESSION_TASK_DIR/test_results.md" ]]; then
        if grep -qi "Verdict:.*FAIL" "$SESSION_TASK_DIR/test_results.md"; then
            log_warn "Tests reported FAIL verdict"
            return 1
        fi
    fi

    log_success "Testing complete"
    return 0
}

# ─── Test with retry loop ────────────────────────────────────────────────────

phase_test_with_retries() {
    local attempt
    for attempt in $(seq 1 "$TEST_RETRY_LIMIT"); do
        log_info "Test attempt $attempt of $TEST_RETRY_LIMIT"

        if phase_test; then
            return 0
        fi

        if [[ $attempt -lt $TEST_RETRY_LIMIT ]]; then
            log_warn "Tests failed — running fix-tests pass..."
            phase_fix || true
        fi
    done

    log_error "Tests failed after $TEST_RETRY_LIMIT attempts"
    return 1
}

# ─── Review (Claude, read-only) ──────────────────────────────────────────────

phase_review() {
    log_phase "review"

    local prompt_file
    prompt_file="$(build_prompt "review")"

    log_info "Invoking Claude Code for review..."

    local output_file="$SESSION_TASK_DIR/review_output.json"

    # Run from project dir so Claude auto-discovers .claude/agents/, .claude/skills/, CLAUDE.md
    (cd "$PROJECT_PATH" && "$CLAUDE_BIN" \
        --print \
        --model "$CLAUDE_MODEL" \
        --effort "$CLAUDE_EFFORT" \
        --dangerously-skip-permissions \
        --output-format json \
        -p "$(cat "$prompt_file")") \
        > "$output_file" 2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Claude review failed (exit $exit_code)"
        cat "$output_file" >&2
        return 1
    fi

    local result
    result="$(jq -r '.result // .content // .' "$output_file" 2>/dev/null || cat "$output_file")"

    # Write review if Claude didn't create the file directly
    if [[ ! -f "$SESSION_TASK_DIR/review.md" ]]; then
        printf '%s\n' "$result" > "$SESSION_TASK_DIR/review.md"
    fi

    # Parse verdict
    local verdict
    verdict="$(grep -oiE 'Verdict:\s*(APPROVE|REQUEST_CHANGES|BLOCK)' "$SESSION_TASK_DIR/review.md" | head -1 | sed 's/.*:\s*//' | tr '[:lower:]' '[:upper:]')"

    case "$verdict" in
        APPROVE)
            log_success "Review verdict: APPROVE"
            return 0
            ;;
        REQUEST_CHANGES)
            log_warn "Review verdict: REQUEST_CHANGES"
            return 2
            ;;
        BLOCK)
            log_error "Review verdict: BLOCK"
            return 3
            ;;
        *)
            log_warn "Could not parse review verdict — treating as REQUEST_CHANGES"
            return 2
            ;;
    esac
}

# ─── Review with retry gate ─────────────────────────────────────────────────

phase_review_with_gate() {
    local attempt
    for attempt in $(seq 0 "$REVIEW_RETRY_LIMIT"); do
        phase_review
        local verdict=$?

        case $verdict in
            0) return 0 ;; # APPROVE
            2) # REQUEST_CHANGES
                if [[ $attempt -lt $REVIEW_RETRY_LIMIT ]]; then
                    log_info "Running fix pass for review feedback..."
                    phase_fix || true
                    phase_test_with_retries || true
                else
                    log_error "Review still requesting changes after $REVIEW_RETRY_LIMIT fix attempts"
                    return 1
                fi
                ;;
            3) # BLOCK
                if [[ $attempt -lt $REVIEW_RETRY_LIMIT ]]; then
                    log_warn "Review BLOCKED — attempting fix..."
                    phase_fix || true
                    phase_test_with_retries || true
                else
                    log_error "Review still BLOCKED after fix attempt"
                    return 1
                fi
                ;;
            *) return 1 ;; # Error
        esac
    done

    return 1
}

# ─── Fix (Codex, write) ─────────────────────────────────────────────────────

phase_fix() {
    log_phase "fix"

    local prompt_file
    prompt_file="$(build_prompt "fix")"

    log_info "Invoking Codex for fixes..."

    local output_file="$SESSION_TASK_DIR/fix_output.md"

    "$CODEX_BIN" exec \
        -m "$CODEX_MODEL" \
        -c model_reasoning_effort="$CODEX_EFFORT" \
        $CODEX_YOLO_FLAG \
        -C "$PROJECT_PATH" \
        -o "$output_file" \
        "$(cat "$prompt_file")" \
        2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Codex fix failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    log_success "Fix pass complete"
    return 0
}

# ─── Document (Codex, write) ─────────────────────────────────────────────────

phase_document() {
    log_phase "document"

    local prompt_file
    prompt_file="$(build_prompt "document")"

    log_info "Invoking Codex for documentation..."

    local output_file="$SESSION_TASK_DIR/document_output.md"

    "$CODEX_BIN" exec \
        -m "$CODEX_MODEL" \
        -c model_reasoning_effort="$CODEX_EFFORT" \
        $CODEX_YOLO_FLAG \
        -C "$PROJECT_PATH" \
        -o "$output_file" \
        "$(cat "$prompt_file")" \
        2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Codex documentation failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    log_success "Documentation complete"
    return 0
}

# ─── Commit (Codex, write, gated) ───────────────────────────────────────────

phase_commit() {
    log_phase "commit"

    # Green flag gate
    if [[ "$AUTO_COMMIT" != "true" ]]; then
        log_info "Commit gate — showing changes:"
        echo ""
        git -C "$PROJECT_PATH" diff --stat
        echo ""
        if ! confirm "Proceed with commit?"; then
            log_warn "Commit aborted by user"
            return 1
        fi
    fi

    local prompt_file
    prompt_file="$(build_prompt "commit")"

    log_info "Invoking Codex for commit..."

    local output_file="$SESSION_TASK_DIR/commit_output.md"

    "$CODEX_BIN" exec \
        -m "$CODEX_MODEL" \
        -c model_reasoning_effort="$CODEX_EFFORT" \
        $CODEX_YOLO_FLAG \
        -C "$PROJECT_PATH" \
        -o "$output_file" \
        "$(cat "$prompt_file")" \
        2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Codex commit failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    log_success "Commit complete"
    return 0
}
