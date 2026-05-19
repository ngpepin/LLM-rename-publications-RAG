#!/usr/bin/env bash
set -euo pipefail

# prefix-by-year.sh
# Rename files in the current directory, or in a directory passed as the first
# argument, when their filenames contain a 4-digit year between 1900 and 2100.
#
# Example:
#   "Book Title (2025).epub"
# becomes:
#   "2025 - Book Title (2025).epub"

# Configure valid year range (inclusive). Update these to change behavior.
MIN_YEAR=1900
MAX_YEAR=2026

echo -e "\033[1;35mPrefixing files with years between $MIN_YEAR and $MAX_YEAR...\033[0m"

usage() {
  cat <<'EOF'
Usage:
  prefix-by-year.sh [DIRECTORY]

Scans regular files in DIRECTORY, or the current directory if none is provided.
For each filename containing a 4-digit year between $MIN_YEAR and $MAX_YEAR, renames it by
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

# Regexes:
# - `paren_year_regex` prefers years inside parentheses like "(2025)".
# - `safe_year_regex` matches a 4-digit year that is not part of a longer
#   digit sequence (prevents matching inside ISBNs).
paren_year_regex='[(]([0-9]{4})[)]'
safe_year_regex='(^|[^0-9])([0-9]{4})([^0-9]|$)'
# Skip files already prefixed with a 4-digit year to avoid double-prefixing.
prefix_regex='^[[:space:]]*([0-9]{4})[[:space:]]-[[:space:]]'

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

  year=""
  if [[ "$filename" =~ $paren_year_regex ]]; then
    year="${BASH_REMATCH[1]}"
  elif [[ "$filename" =~ $safe_year_regex ]]; then
    year="${BASH_REMATCH[2]}"
  fi

  if [[ -z "$year" ]]; then
    continue
  fi

  # Validate numeric bounds
  if (( year < MIN_YEAR || year > MAX_YEAR )); then
    echo "Skip out-of-range year: $filename (year $year not in $MIN_YEAR..$MAX_YEAR)"
    ((skipped++)) || true
    continue
  fi

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
done

if ((dry_run)); then
  echo "Dry run complete. Files that would be renamed: $renamed. Skipped: $skipped."
else
  echo "Done. Files renamed: $renamed. Skipped: $skipped."
fi
