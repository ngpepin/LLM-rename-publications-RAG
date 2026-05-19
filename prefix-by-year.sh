#!/usr/bin/env bash
set -euo pipefail

# prefix-by-year.sh
# Rename files in the current directory, or in a directory passed as the first
# argument, using a year prefix when present.
#
# Example:
#   "Book Title (2025).epub"
# becomes:
#   "2025 - Book Title (2025).epub"
#
# If no year is found, the script prefixes "____ - " instead.

# Configure valid year range (inclusive). Update these to change behavior.
MIN_YEAR=1900
MAX_YEAR=2026

# Most Linux filesystems cap a single path component at 255 bytes.
DEFAULT_NAME_MAX=255

echo -e "\033[1;35mPrefixing files with years between $MIN_YEAR and $MAX_YEAR...\033[0m"

usage() {
  cat <<'EOF'
Usage:
  prefix-by-year.sh [DIRECTORY]

Scans regular files in DIRECTORY, or the current directory if none is provided.
For each filename containing a 4-digit year between $MIN_YEAR and $MAX_YEAR, renames it by
prefixing "<YEAR> - " to the existing filename.
If no year is found, prefixes "____ - " to the filename.

Options:
  -n, --dry-run   Show what would be renamed without making changes.
  -h, --help      Show this help message.
EOF
}

dry_run=0
target_dir="."

byte_len() {
  # Filesystem NAME_MAX is byte-based, not character-based.
  # LC_ALL=C forces single-byte locale semantics so wc -c reflects bytes.
  LC_ALL=C printf '%s' "$1" | wc -c | awk '{print $1}'
}

fit_prefixed_filename() {
  # Build "<year> - <filename>" and truncate stem only when it exceeds NAME_MAX.
  local year="$1"
  local filename="$2"
  local name_max="$3"
  local prefix="${year} - "
  local candidate="${prefix}${filename}"

  if (( $(byte_len "$candidate") <= name_max )); then
    printf '%s\n' "$candidate"
    return 0
  fi

  local ext=""
  local stem="$filename"
  if [[ "$filename" == *.* ]] && [[ "$filename" != .* ]]; then
    ext=".${filename##*.}"
    stem="${filename%.*}"
  fi

  local hash
  # Stable short suffix derived from original filename; helps keep truncated
  # names recognizable and reduces collision risk.
  hash=$(printf '%s' "$filename" | cksum | awk '{print $1}')
  local suffix=" [${hash}]"
  local trimmed="$stem"

  # Trim one character at a time until we fit the filesystem component limit.
  while [[ -n "$trimmed" ]] && (( $(byte_len "${prefix}${trimmed}${suffix}${ext}") > name_max )); do
    trimmed="${trimmed%?}"
  done

  if [[ -z "$trimmed" ]]; then
    return 1
  fi

  printf '%s\n' "${prefix}${trimmed}${suffix}${ext}"
}

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

name_max=$(getconf NAME_MAX "$target_dir" 2>/dev/null || true)
# If NAME_MAX cannot be read on this mount, use a safe default.
if ! [[ "$name_max" =~ ^[0-9]+$ ]]; then
  name_max=$DEFAULT_NAME_MAX
fi

# Regexes:
# - `paren_year_regex` prefers years inside parentheses like "(2025)".
# - `safe_year_regex` matches a 4-digit year that is not part of a longer
#   digit sequence (prevents matching inside ISBNs).
paren_year_regex='[(]([0-9]{4})[)]'
safe_year_regex='(^|[^0-9])([0-9]{4})([^0-9]|$)'
# Skip files already prefixed with "YYYY - " to avoid double-prefixing.
prefix_regex='^[[:space:]]*[0-9]{4} - '
# Also skip files already prefixed with unknown year placeholder.
unknown_prefix_regex='^[[:space:]]*____ - '

renamed=0
skipped=0

shopt -s nullglob dotglob

# This script intentionally processes one directory level only.
for path in "$target_dir"/*; do
  [[ -f "$path" ]] || continue

  filename=${path##*/}

  # Avoid adding another prefix to files already named like "2025 - filename"
  # or "____ - filename".
  if [[ "$filename" =~ $prefix_regex ]] || [[ "$filename" =~ $unknown_prefix_regex ]]; then
    echo "Skip already prefixed: $filename"
    ((skipped++)) || true
    continue
  fi

  year=""

  # Prefer a parenthesized year if it is within range.
  if [[ "$filename" =~ $paren_year_regex ]]; then
    paren_year="${BASH_REMATCH[1]}"
    if (( paren_year >= MIN_YEAR && paren_year <= MAX_YEAR )); then
      year="$paren_year"
    fi
  fi

  # Otherwise scan all safe 4-digit tokens and pick the first in-range year.
  if [[ -z "$year" ]]; then
    # mapfile reads all matching 4-digit tokens into an array.
    # grep -oE emits each regex match on its own line.
    # `|| true` avoids terminating the script under `set -e` when grep finds no matches.
    mapfile -t year_candidates < <(
      printf '%s\n' "$filename" \
        | grep -oE "$safe_year_regex" \
        | grep -oE '[0-9]{4}' || true
    )
    # First in-range token wins.
    for candidate_year in "${year_candidates[@]}"; do
      if (( candidate_year >= MIN_YEAR && candidate_year <= MAX_YEAR )); then
        year="$candidate_year"
        break
      fi
    done
  fi

  # If no valid in-range year is found, use unknown placeholder.
  if [[ -z "$year" ]]; then
    year="____"
  fi

  if ! new_filename=$(fit_prefixed_filename "$year" "$filename" "$name_max"); then
    echo "Skip unable-to-fit name: $filename" >&2
    ((skipped++)) || true
    continue
  fi
  new_path="${target_dir%/}/$new_filename"

    if [[ -e "$new_path" ]]; then
      echo "Skip collision: $filename -> $new_filename" >&2
      ((skipped++)) || true
      continue
    fi

    if ((dry_run)); then
      echo "Would rename: $filename -> $new_filename"
    else
      if mv -- "$path" "$new_path"; then
        echo "Renamed: $filename -> $new_filename"
      else
        echo "Skip mv failed: $filename -> $new_filename" >&2
        ((skipped++)) || true
        continue
      fi
    fi

    ((renamed++)) || true
done

if ((dry_run)); then
  echo "Dry run complete. Files that would be renamed: $renamed. Skipped: $skipped."
else
  echo "Done. Files renamed: $renamed. Skipped: $skipped."
fi
