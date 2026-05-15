#!/usr/bin/env bash
set -euo pipefail

# prefix-by-year.sh
# Rename files in the current directory, or in a directory passed as the first
# argument, when their filenames contain a 4-digit year from 2000 onward.
#
# Example:
#   "Book Title (2025).epub"
# becomes:
#   "2025 - Book Title (2025).epub"

usage() {
  cat <<'EOF'
Usage:
  prefix-by-year.sh [DIRECTORY]

Scans regular files in DIRECTORY, or the current directory if none is provided.
For each filename containing a 4-digit year from 2000 onward, renames it by
prefixing "<YEAR> - " to the existing filename.

Options:
  -n, --dry-run   Show what would be renamed without making changes.
  -h, --help      Show this help message.
EOF
}

dry_run=0
target_dir="."

while (($#)); do
  case "$1" in
    -n|--dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ "$target_dir" != "." ]]; then
        echo "Error: only one directory argument is allowed." >&2
        usage >&2
        exit 2
      fi
      target_dir="$1"
      shift
      ;;
  esac
done

if [[ ! -d "$target_dir" ]]; then
  echo "Error: not a directory: $target_dir" >&2
  exit 1
fi

# Requires Bash's regex support. This matches years 2000-9999.
year_regex='(20[0-9]{2}|[3-9][0-9]{3})'
prefix_regex='^[[:space:]]*(20[0-9]{2}|[3-9][0-9]{3})[[:space:]]-[[:space:]]'

renamed=0
skipped=0

shopt -s nullglob dotglob

for path in "$target_dir"/*; do
  [[ -f "$path" ]] || continue

  filename=${path##*/}

  # Avoid adding another prefix to files already named like "2025 - filename".
  if [[ "$filename" =~ $prefix_regex ]]; then
    echo "Skip already prefixed: $filename"
    ((skipped++)) || true
    continue
  fi

  if [[ "$filename" =~ $year_regex ]]; then
    year="${BASH_REMATCH[1]}"
    new_filename="${year} - ${filename}"
    new_path="${target_dir%/}/$new_filename"

    if [[ -e "$new_path" ]]; then
      echo "Skip collision: $filename -> $new_filename" >&2
      ((skipped++)) || true
      continue
    fi

    if ((dry_run)); then
      echo "Would rename: $filename -> $new_filename"
    else
      mv -- "$path" "$new_path"
      echo "Renamed: $filename -> $new_filename"
    fi

    ((renamed++)) || true
  fi
done

if ((dry_run)); then
  echo "Dry run complete. Files that would be renamed: $renamed. Skipped: $skipped."
else
  echo "Done. Files renamed: $renamed. Skipped: $skipped."
fi
