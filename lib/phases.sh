#!/usr/bin/env bash
# OpusDex phase execution functions
#
# Session continuity:
#   Claude: plan and review share a conversation via --session-id / --resume
#   Codex:  build (implement+test) is one exec call; fix_and_retest is one exec call

# ─── Session State ──────────────────────────────────────────────────────────

CLAUDE_SESSION_ID=""
REVIEW_ROUND=0
LIVE_ATTEMPT=0

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

    local review_file="$SESSION_TASK_DIR/review.md"
    local prior_content=""
    local review_backup=""

    if [[ -f "$review_file" ]]; then
        prior_content="$(cat "$review_file")"
    fi

    local prompt_file
    prompt_file="$(build_prompt "review")"

    # Keep the previous review available while building the prompt, but move it
    # aside before Claude writes a fresh round so we can restore it on failure.
    if [[ -f "$review_file" ]]; then
        review_backup="$(mktemp "$SESSION_TASK_DIR/review_backup.XXXXXX.md")"
        cp "$review_file" "$review_backup"
        rm -f "$review_file"
    fi

    log_info "Invoking Claude Code for review (round $REVIEW_ROUND)..."

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
        rm -f "$review_file"
        if [[ -n "$review_backup" && -f "$review_backup" ]]; then
            mv "$review_backup" "$review_file"
        fi
        cat "$output_file" >&2
        return 1
    fi

    local result
    result="$(jq -r '.result // .content // .' "$output_file" 2>/dev/null || cat "$output_file")"

    # Write review if Claude didn't create the file directly
    if [[ ! -f "$review_file" ]]; then
        printf '%s\n' "$result" > "$review_file"
    fi

    # Prepend prior reviews to build the accumulated history
    if [[ -n "$prior_content" ]]; then
        local new_content
        new_content="$(cat "$review_file")"
        printf '%s\n\n---\n\n%s\n' "$prior_content" "$new_content" > "$review_file"
    fi

    rm -f "$review_backup"
    rm -f "$SESSION_TASK_DIR/live_feedback.md"

    # Parse the LAST verdict (latest round) from accumulated reviews
    local verdict
    verdict="$(grep -oiE 'Verdict:\s*(APPROVE|REQUEST_CHANGES|BLOCK)' "$review_file" | tail -1 | sed 's/.*:\s*//' | tr '[:lower:]' '[:upper:]')"

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
        REVIEW_ROUND=$((REVIEW_ROUND + 1))
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

phase_retest_after_live() {
    log_phase "fix"

    local prompt_file
    prompt_file="$(build_prompt "retest_after_live")"

    log_info "Invoking Codex for post-live verification..."

    local output_file="$SESSION_TASK_DIR/retest_after_live_output.md"

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
        log_error "Codex post-live verification failed (exit $exit_code)"
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    if [[ -f "$SESSION_TASK_DIR/test_results.md" ]] \
        && grep -qi "Verdict:.*FAIL" "$SESSION_TASK_DIR/test_results.md"; then
        log_warn "Post-live verification reported FAIL verdict"
        return 1
    fi

    log_success "Post-live verification complete"
    return 0
}

tracked_state_fingerprint() {
    (
        cd "$PROJECT_PATH" || exit 1
        {
            git status --short --untracked-files=no
            git diff --binary --no-ext-diff --
            git diff --cached --binary --no-ext-diff --
        } | cksum | awk '{print $1 ":" $2}'
    )
}

clear_live_feedback() {
    rm -f "$SESSION_TASK_DIR/live_feedback.md"
}

persist_live_feedback() {
    local source_file="$1"
    local summary="$2"
    local feedback_file="$SESSION_TASK_DIR/live_feedback.md"

    {
        echo "# Live Feedback"
        echo
        echo "## Summary"
        echo "$summary"
        echo
        echo "## Attempt"
        echo "$LIVE_ATTEMPT"
        echo
        echo "## Details"
        if [[ -f "$source_file" ]]; then
            cat "$source_file"
        else
            echo "[no live output captured]"
        fi
    } > "$feedback_file"
}

require_live_dependencies() {
    if ! command -v "$CURSOR_BIN" &>/dev/null && [[ ! -x "$CURSOR_BIN" ]]; then
        log_error "Required command not found: $CURSOR_BIN"
        return 1
    fi

    return 0
}

# ─── Live Pass (Cursor, gated) ──────────────────────────────────────────────

phase_live() {
    log_phase "live"

    local prompt_file
    prompt_file="$(build_prompt "live")"

    log_info "Invoking Cursor agent for live environment pass (attempt $LIVE_ATTEMPT)..."

    local output_file="$SESSION_TASK_DIR/live_output_${LIVE_ATTEMPT}.md"

    (cd "$PROJECT_PATH" && "$CURSOR_BIN" \
        --model "$CURSOR_MODEL" \
        $CURSOR_YOLO_FLAG \
        --print \
        --output-format text \
        --trust \
        --approve-mcps \
        "$(cat "$prompt_file")") \
        > "$output_file" 2>&1

    local exit_code=$?
    rm -f "$prompt_file"

    if [[ $exit_code -ne 0 ]]; then
        log_error "Cursor live pass failed (exit $exit_code)"
        local failure_source="$output_file"
        if [[ -f "$SESSION_TASK_DIR/live_results.md" ]]; then
            failure_source="$SESSION_TASK_DIR/live_results.md"
        fi
        persist_live_feedback "$failure_source" \
            "Cursor agent CLI exited with code $exit_code during live attempt $LIVE_ATTEMPT."
        [[ -f "$output_file" ]] && cat "$output_file" >&2
        return 1
    fi

    # Write live_results.md from output if Cursor didn't create it directly
    if [[ ! -f "$SESSION_TASK_DIR/live_results.md" ]]; then
        cp "$output_file" "$SESSION_TASK_DIR/live_results.md"
    fi

    # Parse verdict from live_results.md
    local verdict
    verdict="$(grep -oiE 'Verdict:\s*(PASS|FAIL)' "$SESSION_TASK_DIR/live_results.md" 2>/dev/null | tail -1 | sed 's/.*:\s*//' | tr '[:lower:]' '[:upper:]')"

    case "$verdict" in
        PASS)
            log_success "Live pass verdict: PASS"
            return 0
            ;;
        FAIL)
            log_warn "Live pass verdict: FAIL"
            persist_live_feedback "$SESSION_TASK_DIR/live_results.md" \
                "Cursor reported a failing live validation verdict on attempt $LIVE_ATTEMPT."
            return 1
            ;;
        *)
            log_warn "Could not parse live verdict — treating as FAIL"
            persist_live_feedback "$SESSION_TASK_DIR/live_results.md" \
                "Cursor did not produce a parseable live verdict on attempt $LIVE_ATTEMPT."
            return 1
            ;;
    esac
}

phase_live_inner() {
    local attempt
    local pre_live_fingerprint
    pre_live_fingerprint="$(tracked_state_fingerprint)"

    for attempt in $(seq 1 "$LIVE_RETRY_LIMIT"); do
        LIVE_ATTEMPT=$attempt

        # Clear previous live_results.md so we parse fresh output
        rm -f "$SESSION_TASK_DIR/live_results.md"

        phase_live
        local result=$?

        if [[ $result -eq 0 ]]; then
            local post_live_fingerprint
            post_live_fingerprint="$(tracked_state_fingerprint)"
            clear_live_feedback

            if [[ "$pre_live_fingerprint" != "$post_live_fingerprint" ]]; then
                log_warn "Live pass succeeded, but Cursor changed tracked files during live fixes"
                return 2
            fi

            return 0
        fi

        if [[ $attempt -lt $LIVE_RETRY_LIMIT ]]; then
            log_info "Live issue found — Cursor will retry (attempt $((attempt + 1))/$LIVE_RETRY_LIMIT)..."
        else
            log_error "Live pass failed after $LIVE_RETRY_LIMIT Cursor attempts"
            return 1
        fi
    done

    return 1
}

# ─── Review + Live outer loop ──────────────────────────────────────────────

phase_review_and_live() {
    local mode="${1:-normal}"
    local live_cycle=0
    local review_needed=true
    local should_prompt_for_live=true

    if [[ "$mode" == "live_resume" ]]; then
        review_needed=false
        should_prompt_for_live=false
    fi

    while true; do
        if [[ "$review_needed" == true ]]; then
            live_cycle=$((live_cycle + 1))
            if [[ $live_cycle -gt $LIVE_REVIEW_LIMIT ]]; then
                log_error "Review↔live cycle failed after $LIVE_REVIEW_LIMIT attempts"
                return 1
            fi

            phase_review_with_gate
            local review_result=$?
            if [[ $review_result -ne 0 ]]; then
                return 1
            fi

            review_needed=false
        fi

        if [[ "$AUTO_LIVE" == "skip" ]]; then
            log_info "Skipping live pass (--skip-live)"
            return 0
        fi

        if [[ "$should_prompt_for_live" == true && "$AUTO_LIVE" != "true" ]]; then
            echo ""
            log_info "Live environment pass — runs the app and checks logs for runtime issues."
            echo ""
            if ! confirm "Run live environment pass?"; then
                log_info "Skipping live pass — proceeding to documentation"
                return 0
            fi
        fi

        should_prompt_for_live=false
        require_live_dependencies || return 1

        phase_live_inner
        local live_result=$?

        case "$live_result" in
            0)
                return 0
                ;;
            1)
                if [[ $live_cycle -ge $LIVE_REVIEW_LIMIT ]]; then
                    log_error "Review↔live cycle failed after $LIVE_REVIEW_LIMIT attempts"
                    return 1
                fi

                log_warn "Live pass failed — falling back to Claude review and Codex fixes"
                review_needed=true
                ;;
            2)
                log_warn "Cursor fixed runtime issues during live validation — running tests and review before final live confirmation"
                phase_retest_after_live || return 1
                review_needed=true
                ;;
            *)
                return 1
                ;;
        esac
    done
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
