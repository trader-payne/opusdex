#!/usr/bin/env bash
# OpusDex color-coded logging

# Colors
readonly CLR_RESET='\033[0m'
readonly CLR_BLUE='\033[0;34m'       # plan
readonly CLR_GREEN='\033[0;32m'      # implement
readonly CLR_YELLOW='\033[0;33m'     # test
readonly CLR_CYAN='\033[0;36m'       # review
readonly CLR_MAGENTA='\033[0;35m'    # fix
readonly CLR_WHITE='\033[0;37m'      # document
readonly CLR_BOLD_CYAN='\033[1;36m'  # live
readonly CLR_BOLD_GREEN='\033[1;32m' # commit
readonly CLR_RED='\033[0;31m'        # error
readonly CLR_BOLD='\033[1m'

# Phase-to-color mapping
declare -A PHASE_COLORS=(
    [plan]="$CLR_BLUE"
    [implement]="$CLR_GREEN"
    [test]="$CLR_YELLOW"
    [review]="$CLR_CYAN"
    [fix]="$CLR_MAGENTA"
    [live]="$CLR_BOLD_CYAN"
    [document]="$CLR_WHITE"
    [commit]="$CLR_BOLD_GREEN"
)

log_separator() {
    printf '%s\n' "$(printf '%.0s─' {1..70})"
}

log_phase() {
    local name="$1"
    local color="${PHASE_COLORS[${name,,}]:-$CLR_BOLD}"
    echo ""
    log_separator
    printf "${color}${CLR_BOLD}  ▶ PHASE: %s${CLR_RESET}\n" "${name^^}"
    log_separator
    echo ""
}

log_info() {
    printf "${CLR_BLUE}[INFO]${CLR_RESET}  %s\n" "$*"
}

log_success() {
    printf "${CLR_GREEN}[OK]${CLR_RESET}    %s\n" "$*"
}

log_warn() {
    printf "${CLR_YELLOW}[WARN]${CLR_RESET}  %s\n" "$*"
}

log_error() {
    printf "${CLR_RED}[ERROR]${CLR_RESET} %s\n" "$*"
}
