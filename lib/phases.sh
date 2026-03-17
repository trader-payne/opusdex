#!/usr/bin/env bash
# OpusDex phase execution functions
#
# Session continuity:
#   Claude: plan and review share a conversation via --session-id / --resume
#   Codex:  build (implement+test) is one exec call; fix_and_retest is one exec call

# ─── Session State ──────────────────────────────────────────────────────────

CLAUDE_SESSION_ID=""

generate_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || uuidgen 2>/dev/null \
        || python3 -c 'import uuid; print(uuid.uuid4())'
}

# ─── Plan (Claude, interactive) ──────────────────────────────────────────────

phase_plan() {
    log_phase "plan"

    if [[ -n "$CLAUDE_SESSION_ID" ]]; then
        log_info "Resuming plan session: $CLAUDE_SESSION_ID"
        log_info "Continue the discussion, then Claude will write todo.md. Exit with /exit when done."
        echo ""

        (cd "$PROJECT_PATH" && "$CLAUDE_BIN" \
            --model "$CLAUDE_MODEL" \
            --effort "$CLAUDE_EFFORT" \
            --verbose \
            --dangerously-skip-permissions \
            --resume "$CLAUDE_SESSION_ID" \
            "Let's continue. When ready, write the plan to $SESSION_TASK_DIR/todo.md." \
            </dev/tty >/dev/tty 2>&1) || true
    else
        local prompt_files system_prompt_file task_prompt_file
        prompt_files="$(build_plan_prompts)"
        system_prompt_file="$(echo "$prompt_files" | head -1)"
        task_prompt_file="$(echo "$prompt_files" | tail -1)"

        # Generate a session ID so we can resume this conversation in the review phase
        CLAUDE_SESSION_ID="$(generate_uuid)"
        echo "$CLAUDE_SESSION_ID" > "$SESSION_TASK_DIR/claude_session_id"
        log_info "Claude session: $CLAUDE_SESSION_ID"

        log_info "Starting interactive planning session with Claude..."
        log_info "Discuss the plan, then Claude will write todo.md. Exit with /exit or Ctrl+C when done."
        echo ""

        # Attach Claude directly to the controlling terminal. The orchestrator's
        # session-wide tee logging makes stdout non-TTY, which causes Claude to
        # behave like a one-shot run instead of holding an interactive session.
        (cd "$PROJECT_PATH" && "$CLAUDE_BIN" \
            --model "$CLAUDE_MODEL" \
            --effort "$CLAUDE_EFFORT" \
            --verbose \
            --dangerously-skip-permissions \
            --session-id "$CLAUDE_SESSION_ID" \
            --system-prompt "$(cat "$system_prompt_file")" \
            "$(cat "$task_prompt_file")" \
            </dev/tty >/dev/tty 2>&1) || true

        rm -f "$system_prompt_file" "$task_prompt_file"
    fi

    # Verify todo.md was produced
    if [[ ! -f "$SESSION_TASK_DIR/todo.md" ]]; then
        log_error "todo.md was not created during planning session"
        log_info "Re-run with --phase plan to try again"
        return 1
    fi

    log_success "Planning complete — see $SESSION_TASK_DIR/todo.md"

    # Plan approval gate
    if [[ "$AUTO_PLAN" != "true" ]]; then
        echo ""
        log_info "Plan produced — review it at: $SESSION_TASK_DIR/todo.md"
        echo ""
        if ! confirm "Approve plan and proceed to build?"; then
            log_warn "Plan not approved — aborting"
            log_info "Re-run with --phase plan to revise"
            return 1
        fi
    fi

    return 0
}

# ─── Build (Codex, implement + test in one session) ─────────────────────────

phase_build() {
    log_phase "build"

    local prompt_file
    prompt_file="$(build_prompt "build")"

    log_info "Invoking Codex for implementation + testing..."

    local output_file="$SESSION_TASK_DIR/build_output.md"

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
        log_error "Codex build failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    # Check test verdict
    if [[ -f "$SESSION_TASK_DIR/test_results.md" ]]; then
        if grep -qi "Verdict:.*FAIL" "$SESSION_TASK_DIR/test_results.md"; then
            log_warn "Tests reported FAIL verdict after build"
            return 1
        fi
    fi

    log_success "Build complete (implementation + tests passed)"
    return 0
}

# ─── Review (Claude, continues plan session) ────────────────────────────────

phase_review() {
    log_phase "review"

    local prompt_file
    prompt_file="$(build_prompt "review")"

    log_info "Invoking Claude Code for review..."

    local output_file="$SESSION_TASK_DIR/review_output.json"

    # Build Claude args — resume plan session if available for full context continuity
    local -a claude_args=(
        --print
        --model "$CLAUDE_MODEL"
        --effort "$CLAUDE_EFFORT"
        --dangerously-skip-permissions
        --output-format json
    )

    if [[ -n "$CLAUDE_SESSION_ID" ]]; then
        claude_args+=(--resume "$CLAUDE_SESSION_ID")
        log_info "Continuing Claude plan session for review context"
    fi

    claude_args+=(-p "$(cat "$prompt_file")")

    # Run from project dir so Claude auto-discovers .claude/agents/, .claude/skills/, CLAUDE.md
    (cd "$PROJECT_PATH" && "$CLAUDE_BIN" "${claude_args[@]}") \
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
            2|3) # REQUEST_CHANGES or BLOCK
                if [[ $attempt -lt $REVIEW_RETRY_LIMIT ]]; then
                    log_info "Running fix + retest pass..."
                    phase_fix_and_retest || true
                else
                    log_error "Review not approved after $REVIEW_RETRY_LIMIT fix attempts"
                    return 1
                fi
                ;;
            *) return 1 ;; # Error
        esac
    done

    return 1
}

# ─── Fix & Retest (Codex, fix + test in one session) ────────────────────────

phase_fix_and_retest() {
    log_phase "fix"

    local prompt_file
    prompt_file="$(build_prompt "fix_and_retest")"

    log_info "Invoking Codex for fixes + retesting..."

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

    log_success "Fix + retest complete"
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
