#!/usr/bin/env bash

set -Eeuo pipefail

resolve_script_dir() {
    local source="${BASH_SOURCE[0]}"
    local dir=""

    while [[ -L "$source" ]]; do
        dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done

    cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
VENV_DIR="${RENAME_USING_LLM_VENV:-$SCRIPT_DIR/venv}"
TARGET_SCRIPT="${RENAME_USING_LLM_SCRIPT:-$SCRIPT_DIR/rename-using-llm.sh}"
VENV_ACTIVATED=0
CHILD_PID=""

usage() {
    cat <<EOF
Usage: $(basename "$0") /path/to/books

Activates the project virtual environment and runs rename-using-llm.sh.

Environment overrides:
  RENAME_USING_LLM_VENV     Path to the virtual environment directory
  RENAME_USING_LLM_SCRIPT   Path to the script to launch
EOF
}

cleanup() {
    local exit_code=$?

    trap - EXIT INT TERM HUP

    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" >/dev/null 2>&1; then
        kill "$CHILD_PID" >/dev/null 2>&1 || true
        wait "$CHILD_PID" >/dev/null 2>&1 || true
    fi

    if [[ "$VENV_ACTIVATED" -eq 1 ]] && declare -F deactivate >/dev/null 2>&1; then
        deactivate || true
    fi

    exit "$exit_code"
}

forward_signal_and_exit() {
    local signal_name="$1"
    local exit_code="$2"

    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" >/dev/null 2>&1; then
        kill -"$signal_name" "$CHILD_PID" >/dev/null 2>&1 || true
    fi

    exit "$exit_code"
}

trap cleanup EXIT
trap 'forward_signal_and_exit INT 130' INT
trap 'forward_signal_and_exit TERM 143' TERM
trap 'forward_signal_and_exit HUP 129' HUP

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
    echo "Error: virtual environment not found at '$VENV_DIR'." >&2
    echo "Create it with: python3 -m venv '$VENV_DIR'" >&2
    exit 1
fi

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "Error: target script not found at '$TARGET_SCRIPT'." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
VENV_ACTIVATED=1

set +e
bash "$TARGET_SCRIPT" "$@" &
CHILD_PID=$!
wait "$CHILD_PID"
RUN_STATUS=$?
CHILD_PID=""
set -e

exit "$RUN_STATUS"
