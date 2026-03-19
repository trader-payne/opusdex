#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

assert_file_contains() {
    local file="$1"
    local needle="$2"

    if ! rg -Fq -- "$needle" "$file"; then
        echo "Expected to find '$needle' in $file" >&2
        return 1
    fi
}

assert_equals() {
    local expected="$1"
    local actual="$2"

    if [[ "$expected" != "$actual" ]]; then
        echo "Expected '$expected' but got '$actual'" >&2
        return 1
    fi
}

read_counter() {
    local file="$1"
    [[ -f "$file" ]] && cat "$file" || echo 0
}

create_target_repo() {
    local repo_dir="$1"

    mkdir -p "$repo_dir"
    git -C "$repo_dir" init -q
    git -C "$repo_dir" config user.email "tests@example.com"
    git -C "$repo_dir" config user.name "OpusDex Tests"

    cat > "$repo_dir/app.txt" <<'EOF'
base
EOF

    git -C "$repo_dir" add app.txt
    git -C "$repo_dir" commit -qm "base"
}

create_stubs() {
    local tmp_dir="$1"
    local bin_dir="$tmp_dir/bin"

    mkdir -p "$bin_dir" "$tmp_dir/state"

    cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
args=("$@")
index=0
while [[ $index -lt ${#args[@]} ]]; do
    case "${args[$index]}" in
        -p|--prompt)
            index=$((index + 1))
            prompt="${args[$index]:-}"
            ;;
    esac
    index=$((index + 1))
done

state_dir="${STUB_STATE_DIR:?}"
mkdir -p "$state_dir"

if [[ "$prompt" == *"# Review Phase"* ]]; then
    count_file="$state_dir/claude_review_count"
    count=0
    [[ -f "$count_file" ]] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf '%s' "$prompt" > "$state_dir/claude_review_prompt_${count}.txt"

    if [[ "${CLAUDE_FAIL_ON_REVIEW:-0}" == "1" ]]; then
        exit 1
    fi

    cat <<'REVIEW_EOF'
# Code Review — Round 1

## Summary
Stub review.

## Findings

### Critical
- none

### Suggestions
- none

### Positive
- stub

## Verdict: APPROVE
REVIEW_EOF
    exit 0
fi

if [[ "$prompt" == *"memory curator for an AI development orchestrator"* ]]; then
    case "${CLAUDE_MEMORY_MODE:-valid}" in
        header_only)
            cat <<'MEMORY_EOF'
# Shared Context
> Project knowledge shared between Claude Code and Codex.
MEMORY_EOF
            ;;
        *)
            cat <<'MEMORY_EOF'
# Shared Context
> Project knowledge shared between Claude Code and Codex.

### Rule: Curated rule
- **Why**: Stubbed memory curation result.
- **How to apply**: Keep the rule.
MEMORY_EOF
            ;;
    esac
    exit 0
fi

printf '%s\n' "${CLAUDE_DEFAULT_OUTPUT:-stub}"
EOF

    cat > "$bin_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

output_file=""
prompt=""
args=("$@")
index=0
while [[ $index -lt ${#args[@]} ]]; do
    case "${args[$index]}" in
        -o)
            index=$((index + 1))
            output_file="${args[$index]:-}"
            ;;
        *)
            prompt="${args[$index]}"
            ;;
    esac
    index=$((index + 1))
done

state_dir="${STUB_STATE_DIR:?}"
mkdir -p "$state_dir"

if [[ -n "$output_file" ]]; then
    printf 'stub codex output\n' > "$output_file"
fi

session_dir="$(sed -n 's/.*Session directory: `\(.*\)`/\1/p' <<<"$prompt" | tail -1)"

if [[ "$prompt" == *"# Post-Live Verification"* ]]; then
    count_file="$state_dir/codex_post_live_count"
    count=0
    [[ -f "$count_file" ]] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    printf '%s' "$prompt" > "$state_dir/codex_post_live_prompt_${count}.txt"

    if [[ -n "$session_dir" ]]; then
        mkdir -p "$session_dir"
        cat > "$session_dir/test_results.md" <<'TEST_EOF'
# Test Results

## Existing Tests
- Status: PASS
- Output summary

## New Tests
- None

## Acceptance Criteria
- [x] Post-live fixes hold under tests

## Verdict: PASS
TEST_EOF
    fi
fi

exit 0
EOF

    cat > "$bin_dir/gemini" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt=""
args=("$@")
index=0
while [[ $index -lt ${#args[@]} ]]; do
    case "${args[$index]}" in
        -p|--prompt)
            index=$((index + 1))
            prompt="${args[$index]:-}"
            ;;
    esac
    index=$((index + 1))
done

state_dir="${STUB_STATE_DIR:?}"
mkdir -p "$state_dir"

count_file="$state_dir/gemini_count"
count=0
[[ -f "$count_file" ]] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf '%s' "$prompt" > "$state_dir/gemini_prompt_${count}.txt"

IFS=',' read -r -a actions <<< "${GEMINI_SEQUENCE:-pass_clean}"
action="${actions[$((count - 1))]:-pass_clean}"

case "$action" in
    pass_clean)
        cat <<'LIVE_EOF'
# Live Environment Results

## Environment
- Stub

## Checks Performed
- Stub check — PASS

## Issues Found
- None

## Verdict: PASS
LIVE_EOF
        ;;
    pass_change)
        printf 'gemini change %s\n' "$count" >> app.txt
        cat <<'LIVE_EOF'
# Live Environment Results

## Environment
- Stub

## Checks Performed
- Stub check — PASS

## Issues Found
- Fixed during live attempt

## Verdict: PASS
LIVE_EOF
        ;;
    fail_verdict)
        cat <<'LIVE_EOF'
# Live Environment Results

## Environment
- Stub

## Checks Performed
- Stub check — FAIL

## Issues Found
- Runtime failure detected

## Verdict: FAIL
LIVE_EOF
        ;;
    exit1)
        echo "gemini crashed during startup"
        exit 1
        ;;
    *)
        echo "Unknown Gemini stub action: $action" >&2
        exit 1
        ;;
esac
EOF

    chmod +x "$bin_dir/claude" "$bin_dir/codex" "$bin_dir/gemini"

    export STUB_STATE_DIR="$tmp_dir/state"
    export CLAUDE_BIN="$bin_dir/claude"
    export CODEX_BIN="$bin_dir/codex"
    export GEMINI_BIN="$bin_dir/gemini"
}

load_libs() {
    export OPUSDEX_DIR="$ROOT_DIR"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/config.env"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/utils.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/logging.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/memory.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/prompts.sh"
    # shellcheck source=/dev/null
    source "$ROOT_DIR/lib/phases.sh"
}

init_function_test_context() {
    local tmp_dir="$1"

    create_target_repo "$tmp_dir/project"
    load_libs

    PROJECT_PATH="$tmp_dir/project"
    PROJECT_DATA_DIR="$PROJECT_PATH/.opusdex"
    SESSION_TASK_DIR="$PROJECT_DATA_DIR/tasks/session"
    TASK_DESCRIPTION="Test task"
    BASELINE_COMMIT="$(git -C "$PROJECT_PATH" rev-parse HEAD)"
    SESSION_START="$(date +%s)"
    CLAUDE_SESSION_ID=""
    REVIEW_ROUND=0
    LIVE_ATTEMPT=0

    init_project_data_dir
    ensure_dir "$SESSION_TASK_DIR"
    init_memory_files
}

test_review_prompt_includes_live_feedback() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    init_function_test_context "$tmp_dir"

    printf 'prior review marker\n' > "$SESSION_TASK_DIR/review.md"
    printf '# Live Feedback\nruntime failure marker\n' > "$SESSION_TASK_DIR/live_feedback.md"
    printf '# Test Results\n\n## Verdict: PASS\n' > "$SESSION_TASK_DIR/test_results.md"

    local prompt_file
    prompt_file="$(build_prompt review)"

    assert_file_contains "$prompt_file" "prior review marker"
    assert_file_contains "$prompt_file" "runtime failure marker"

    rm -rf "$tmp_dir" "$prompt_file"
}

test_review_failure_restores_previous_review() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    init_function_test_context "$tmp_dir"

    export CLAUDE_FAIL_ON_REVIEW=1
    printf 'previous review survives\n' > "$SESSION_TASK_DIR/review.md"

    if phase_review; then
        echo "phase_review unexpectedly succeeded" >&2
        return 1
    fi

    assert_file_contains "$SESSION_TASK_DIR/review.md" "previous review survives"

    rm -rf "$tmp_dir"
}

test_memory_curation_header_only_falls_back() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    init_function_test_context "$tmp_dir"

    export CLAUDE_MEMORY_MODE=header_only

    cat > "$PROJECT_DATA_DIR/memory/shared_context.md" <<'EOF'
# Shared Context
> Project knowledge shared between Claude Code and Codex.

### Rule: Preserve existing memory
- **Why**: Existing guidance must survive.
- **How to apply**: Keep it.
EOF

    cat > "$SESSION_TASK_DIR/lessons.md" <<'EOF'
### Rule: New lesson
- **Why**: Fresh lesson from the session.
- **How to apply**: Add it.
EOF

    merge_session_lessons "$SESSION_TASK_DIR"

    assert_file_contains "$PROJECT_DATA_DIR/memory/shared_context.md" "### Rule: Preserve existing memory"
    assert_file_contains "$PROJECT_DATA_DIR/memory/shared_context.md" "### Rule: New lesson"

    rm -rf "$tmp_dir"
}

test_legacy_memory_migrates_into_shared_context() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"

    create_target_repo "$tmp_dir/project"
    load_libs

    PROJECT_PATH="$tmp_dir/project"
    PROJECT_DATA_DIR="$PROJECT_PATH/.opusdex"
    ensure_dir "$PROJECT_DATA_DIR/memory"

    cat > "$PROJECT_DATA_DIR/memory/claude_lessons.md" <<'EOF'
### Rule: Claude legacy rule
- **Why**: Legacy Claude rule.
- **How to apply**: Migrate it.
EOF

    cat > "$PROJECT_DATA_DIR/memory/codex_lessons.md" <<'EOF'
### Rule: Codex legacy rule
- **Why**: Legacy Codex rule.
- **How to apply**: Migrate it too.
EOF

    init_memory_files

    assert_file_contains "$PROJECT_DATA_DIR/memory/shared_context.md" "### Rule: Claude legacy rule"
    assert_file_contains "$PROJECT_DATA_DIR/memory/shared_context.md" "### Rule: Codex legacy rule"

    rm -rf "$tmp_dir"
}

test_post_live_change_requires_retest_and_second_live() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    init_function_test_context "$tmp_dir"

    export AUTO_LIVE=true
    export REVIEW_RETRY_LIMIT=0
    export LIVE_RETRY_LIMIT=1
    export LIVE_REVIEW_LIMIT=2
    export GEMINI_SEQUENCE="pass_change,pass_clean"

    phase_review_and_live "normal"

    assert_equals "2" "$(read_counter "$STUB_STATE_DIR/claude_review_count")"
    assert_equals "1" "$(read_counter "$STUB_STATE_DIR/codex_post_live_count")"
    assert_equals "2" "$(read_counter "$STUB_STATE_DIR/gemini_count")"

    rm -rf "$tmp_dir"
}

test_live_resume_failure_falls_back_to_review_with_feedback() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    init_function_test_context "$tmp_dir"

    export AUTO_LIVE=true
    export REVIEW_RETRY_LIMIT=0
    export LIVE_RETRY_LIMIT=1
    export LIVE_REVIEW_LIMIT=2
    export GEMINI_SEQUENCE="fail_verdict,pass_clean"

    phase_review_and_live "live_resume"

    assert_equals "1" "$(read_counter "$STUB_STATE_DIR/claude_review_count")"
    assert_equals "2" "$(read_counter "$STUB_STATE_DIR/gemini_count")"
    assert_file_contains "$STUB_STATE_DIR/claude_review_prompt_1.txt" "Gemini reported a failing live validation verdict"

    rm -rf "$tmp_dir"
}

test_orchestrate_allows_missing_gemini_when_live_skipped() {
    local tmp_dir output_file
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    create_target_repo "$tmp_dir/project"
    output_file="$tmp_dir/orchestrate_skip_live.log"

    if ! env \
        OPUSDEX_DIR="$ROOT_DIR" \
        CLAUDE_BIN="$CLAUDE_BIN" \
        CODEX_BIN="$CODEX_BIN" \
        GEMINI_BIN="$tmp_dir/bin/missing-gemini" \
        AUTO_LIVE=skip \
        STUB_STATE_DIR="$STUB_STATE_DIR" \
        bash "$ROOT_DIR/orchestrate.sh" "Skip live" --project "$tmp_dir/project" --phase review --auto-commit \
        > "$output_file" 2>&1; then
        cat "$output_file" >&2
        return 1
    fi

    if rg -Fq "Required command not found" "$output_file"; then
        echo "Gemini should not be required when live is skipped" >&2
        cat "$output_file" >&2
        return 1
    fi

    rm -rf "$tmp_dir"
}

test_orchestrate_fails_when_live_entered_without_gemini() {
    local tmp_dir output_file
    tmp_dir="$(mktemp -d)"
    create_stubs "$tmp_dir"
    create_target_repo "$tmp_dir/project"
    output_file="$tmp_dir/orchestrate_live_fail.log"

    if env \
        OPUSDEX_DIR="$ROOT_DIR" \
        CLAUDE_BIN="$CLAUDE_BIN" \
        CODEX_BIN="$CODEX_BIN" \
        GEMINI_BIN="$tmp_dir/bin/missing-gemini" \
        STUB_STATE_DIR="$STUB_STATE_DIR" \
        AUTO_LIVE=true \
        bash "$ROOT_DIR/orchestrate.sh" "Run live" --project "$tmp_dir/project" --phase live --auto-commit \
        > "$output_file" 2>&1; then
        echo "orchestrate.sh unexpectedly succeeded without Gemini" >&2
        cat "$output_file" >&2
        return 1
    fi

    assert_file_contains "$output_file" "Required command not found: $tmp_dir/bin/missing-gemini"

    rm -rf "$tmp_dir"
}

run_test() {
    local name="$1"
    shift

    if ( "$@" ); then
        printf 'ok - %s\n' "$name"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        printf 'not ok - %s\n' "$name"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

run_test "review prompt includes live feedback" test_review_prompt_includes_live_feedback
run_test "review failure restores prior review" test_review_failure_restores_previous_review
run_test "memory curation header-only output falls back safely" test_memory_curation_header_only_falls_back
run_test "legacy memory migrates into shared context" test_legacy_memory_migrates_into_shared_context
run_test "live changes trigger post-live retest and second live pass" test_post_live_change_requires_retest_and_second_live
run_test "live resume failure falls back to review with feedback" test_live_resume_failure_falls_back_to_review_with_feedback
run_test "orchestrate skips Gemini when live is declined" test_orchestrate_allows_missing_gemini_when_live_skipped
run_test "orchestrate fails at live entry when Gemini is missing" test_orchestrate_fails_when_live_entered_without_gemini

printf '\nPassed: %d\n' "$PASS_COUNT"
printf 'Failed: %d\n' "$FAIL_COUNT"

if [[ $FAIL_COUNT -ne 0 ]]; then
    exit 1
fi
