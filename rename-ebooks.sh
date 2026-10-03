#!/bin/bash

set -euo pipefail

resolve_script_path() {
    local source="${BASH_SOURCE[0]}"
    local dir

    while [[ -L "$source" ]]; do
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ "$source" != /* ]] && source="$dir/$source"
    done

    dir="$(cd -P "$(dirname "$source")" && pwd)"
    printf '%s/%s\n' "$dir" "$(basename "$source")"
}

usage() {
    cat <<'EOF'
Usage: rename-ebooks.sh [-l|--llm | -e|--ebook-tools] /path/to/books

Runs the project's main rename-and-convert workflow.

Options:
  -l, --llm          Use the LLM rename flow (default)
  -e, --ebook-tools  Use the ebook-tools metadata flow
  -h, --help         Show this help and exit
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

SCRIPT_PATH="$(resolve_script_path)"
PROJECT_ROOT="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"
cd "$PROJECT_ROOT"

exec "$PROJECT_ROOT/rename.sh" "$@"
