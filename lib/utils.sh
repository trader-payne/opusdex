#!/usr/bin/env bash
# OpusDex utility functions

ensure_dir() {
    mkdir -p "$1"
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

datestamp() {
    date '+%Y%m%d_%H%M%S'
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null && [[ ! -x "$cmd" ]]; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
}

abort() {
    echo "FATAL: $1" >&2
    exit 1
}

confirm() {
    local prompt="${1:-Continue?}"
    local answer
    # Restore terminal settings that CLI subprocesses (Claude, Codex) may corrupt
    stty echo icrnl icanon </dev/tty 2>/dev/null
    printf "%s [y/N] " "$prompt" >/dev/tty
    read -r answer </dev/tty
    # Strip trailing carriage return (safety net for terminal state issues)
    answer="${answer%$'\r'}"
    [[ "$answer" =~ ^[Yy]$ ]]
}

file_to_prompt() {
    local file="$1"
    local tag="$2"
    if [[ -f "$file" ]]; then
        printf '<%s>\n%s\n</%s>' "$tag" "$(cat "$file")" "$tag"
    fi
}

write_prompt_to_tmpfile() {
    local prompt="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/opusdex_prompt_XXXXXX.md)
    printf '%s' "$prompt" > "$tmpfile"
    echo "$tmpfile"
}

duration_since() {
    local start="$1"
    local now
    now=$(date +%s)
    local elapsed=$((now - start))
    local mins=$((elapsed / 60))
    local secs=$((elapsed % 60))
    printf '%dm %ds' "$mins" "$secs"
}
