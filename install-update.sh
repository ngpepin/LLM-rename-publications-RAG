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
Usage: install-update.sh [--check | --dry-run]

Checks host-side dependencies required by rename-ebooks.

Options:
  --check     Report missing dependencies and exit without changing the system.
  --dry-run   Show the apt command that would be used, without changing the system.
  -h, --help  Show this help and exit.

Without --check/--dry-run, missing packages are shown and installation is offered
interactively. No package installation occurs without explicit confirmation.
EOF
}

MODE="install"
case "${1:-}" in
    "") ;;
    --check) MODE="check" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help) usage; exit 0 ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 2
        ;;
esac

SCRIPT_PATH="$(resolve_script_path)"
PROJECT_ROOT="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd)"

# command:apt-package mappings. pdftotext and pdftoppm intentionally map to
# the same package: multimodal image extraction adds pdftoppm, which is supplied
# by the existing poppler-utils host dependency.
requirements=(
    "jq:jq"
    "pdftotext:poppler-utils"
    "pdftoppm:poppler-utils"
    "ebook-convert:calibre"
    "python3:python3"
    "curl:curl"
    "bc:bc"
)

missing_commands=()
missing_packages=()
for requirement in "${requirements[@]}"; do
    command_name="${requirement%%:*}"
    package_name="${requirement#*:}"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing_commands+=("$command_name")
        seen=false
        for existing in "${missing_packages[@]:-}"; do
            if [[ "$existing" == "$package_name" ]]; then
                seen=true
                break
            fi
        done
        [[ "$seen" == true ]] || missing_packages+=("$package_name")
    fi
done

if ((${#missing_commands[@]} == 0)); then
    echo "All required host commands are available."
    echo "Project root: $PROJECT_ROOT"
    exit 0
fi

echo "Missing required host commands: ${missing_commands[*]}"
echo "Required Debian/Ubuntu packages: ${missing_packages[*]}"

if [[ "$MODE" == "check" ]]; then
    echo "Host dependency check failed; no changes were made."
    exit 1
fi

install_cmd=(sudo apt-get install -y "${missing_packages[@]}")
if [[ "$MODE" == "dry-run" ]]; then
    printf 'Would run:'
    printf ' %q' "${install_cmd[@]}"
    printf '\n'
    echo "No changes were made."
    exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
    echo "Automatic installation is only supported on apt-based Debian/Ubuntu hosts." >&2
    echo "Install the missing commands with your host package manager and rerun --check." >&2
    exit 1
fi

printf 'Install these packages now? [y/N] '
read -r answer
case "$answer" in
    y|Y|yes|YES|Yes)
        "${install_cmd[@]}"
        ;;
    *)
        echo "Installation cancelled; no changes were made."
        exit 1
        ;;
esac

exec "$SCRIPT_PATH" --check
