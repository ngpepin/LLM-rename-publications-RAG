#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENAME_MODE="llm"
TARGET_DIR=""

usage() {
    echo "Usage: $0 [-l|--llm | -e|--ebook-tools] /path/to/books"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -l|--llm)
            RENAME_MODE="llm"
            shift
            ;;
        -e|--ebook-tools)
            RENAME_MODE="ebook-tools"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'."
            usage
            exit 1
            ;;
        *)
            if [[ -n "$TARGET_DIR" ]]; then
                echo "Error: Multiple input directories provided."
                usage
                exit 1
            fi
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET_DIR" ]]; then
    echo "Error: No input directory provided."
    usage
    exit 1
fi

if [[ "$TARGET_DIR" == "." ]]; then
    TARGET_DIR="$(pwd)"
else
    TARGET_DIR="$(realpath "$TARGET_DIR")"
fi

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "Error: Directory '$TARGET_DIR' not found."
    exit 1
fi

run_converter_if_needed() {
    local dir_path="$1"
    local extension="$2"
    local converter_script="$3"

    if find "$dir_path" -maxdepth 1 -type f -name "*.$extension" -print -quit | grep -q .; then
        echo "Running $(basename "$converter_script") in $dir_path"
        "$converter_script" "$dir_path"
    fi
}

echo "Renaming ebooks in $TARGET_DIR"
if [[ "$RENAME_MODE" == "ebook-tools" ]]; then
    "$SCRIPT_DIR/rename-using-ebooks-tools.sh" "$TARGET_DIR"
else
    "$SCRIPT_DIR/rename-using-llm.sh" "$TARGET_DIR"
fi

echo "Converting renamed non-PDF files to PDF where applicable"
while IFS= read -r -d '' dir_path; do
    run_converter_if_needed "$dir_path" "epub" "$SCRIPT_DIR/convert-epub-to-pdf.sh"
    run_converter_if_needed "$dir_path" "mobi" "$SCRIPT_DIR/convert-mobi-to-pdf.sh"
    run_converter_if_needed "$dir_path" "chm" "$SCRIPT_DIR/convert-chm-to-pdf.sh"
    run_converter_if_needed "$dir_path" "azw3" "$SCRIPT_DIR/convert-azw3-to-pdf.sh"
done < <(find "$TARGET_DIR" \
    \( -type d \( -name Originals -o -name Failed -o -name Converted \) -prune \) \
    -o -type d -print0)

echo "Rename and conversion process completed."
