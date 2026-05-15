#!/bin/bash
set -euo pipefail

# -------------------------------------------------------------------
# Function: check_drm
# Returns 0 if true DRM is present, 1 otherwise.
# -------------------------------------------------------------------
check_drm() {
    local epub_file="$1"
    local temp_dir

    temp_dir=$(mktemp -d)
    if ! unzip -q "$epub_file" "META-INF/encryption.xml" -d "$temp_dir" 2>/dev/null; then
        rm -rf "$temp_dir"
        return 1
    fi

    if grep -q "EncryptionMethod.*Algorithm=\"[^\"]*\"" "$temp_dir/META-INF/encryption.xml" | \
       grep -qv "http://www.idpf.org/2008/embedding"; then
        rm -rf "$temp_dir"
        return 0
    else
        rm -rf "$temp_dir"
        return 1
    fi
}

# -------------------------------------------------------------------
# Function: remove_drm_with_calibre
# Takes input EPUB, returns path to DRM-cleaned EPUB.
# -------------------------------------------------------------------
remove_drm_with_calibre() {
    local input_epub="$1"
    local temp_library
    local cleaned_file

    temp_library=$(mktemp -d)
    echo >&2 "  → Adding to temporary Calibre library (DeDRM will trigger)..."
    if ! calibredb add --with-library="$temp_library" "$input_epub" >/dev/null 2>&1; then
        echo >&2 "  ✗ calibredb failed. DRM removal unsuccessful."
        rm -rf "$temp_library"
        return 1
    fi

    cleaned_file=$(find "$temp_library" -name "*.epub" -type f | head -n 1)
    if [[ -z "$cleaned_file" || ! -f "$cleaned_file" ]]; then
        echo >&2 "  ✗ Could not locate cleaned EPUB in temporary library."
        rm -rf "$temp_library"
        return 1
    fi

    local output_file="${input_epub%.epub}_noDRM.epub"
    cp "$cleaned_file" "$output_file"
    rm -rf "$temp_library"
    echo >&2 "  ✓ DRM removed, saved as: $output_file"
    echo "$output_file"
}

# -------------------------------------------------------------------
# Function: strip_pua_characters
# Takes an EPUB, returns path to a new EPUB with PUA chars removed.
# -------------------------------------------------------------------
strip_pua_characters() {
    local input_epub="$1"
    local work_dir
    local output_epub="${input_epub%.epub}_clean.epub"
    local abs_output_epub

    # Get absolute path to the output file
    if ! abs_output_epub="$(realpath "$output_epub" 2>/dev/null)"; then
        abs_output_epub="$PWD/$output_epub"
    fi
    mkdir -p "$(dirname "$abs_output_epub")"

    work_dir=$(mktemp -d)
    echo >&2 "  → Extracting EPUB to strip PUA characters (U+E000–U+F8FF)..."

    if ! unzip -q "$input_epub" -d "$work_dir"; then
        echo >&2 "  ✗ Failed to extract EPUB"
        rm -rf "$work_dir"
        return 1
    fi

    # Remove PUA characters using Python (Unicode-safe)
    find "$work_dir" -type f \( -name "*.xhtml" -o -name "*.html" -o -name "*.htm" \) \
        -exec python3 -c '
import sys, re
pua = re.compile(r"[\uE000-\uF8FF]")
for path in sys.argv[1:]:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    new_content = pua.sub("", content)
    with open(path, "w", encoding="utf-8") as f:
        f.write(new_content)
' {} \;

    if [ $? -ne 0 ]; then
        echo >&2 "  ✗ Failed to strip PUA characters"
        rm -rf "$work_dir"
        return 1
    fi

    # Repack the EPUB directly to the absolute output path
    (cd "$work_dir" && zip -qr "$abs_output_epub" .) > /dev/null 2>&1 || {
        echo >&2 "  ✗ Failed to repack EPUB"
        rm -rf "$work_dir"
        return 1
    }

    rm -rf "$work_dir"
    echo >&2 "  ✓ PUA characters stripped, saved as: $output_epub"
    echo "$output_epub"
}

# -------------------------------------------------------------------
# Function: convert_to_pdf
# Takes an EPUB, converts to PDF using Calibre's ebook-convert.
# -------------------------------------------------------------------
convert_to_pdf() {
    local input_epub="$1"
    local output_pdf="${input_epub%.epub}.pdf"

    echo >&2 "  → Converting to PDF: $output_pdf"
    if ! ebook-convert "$input_epub" "$output_pdf" >/dev/null 2>&1; then
        echo >&2 "  ✗ PDF conversion failed."
        return 1
    fi
    echo >&2 "  ✓ PDF created: $output_pdf"
    echo "$output_pdf"
}

# -------------------------------------------------------------------
# Main script
# -------------------------------------------------------------------
if [ $# -ne 1 ]; then
    echo "Usage: $0 <epub_file>"
    exit 1
fi

INPUT="$1"
if [ ! -f "$INPUT" ]; then
    echo "Error: File '$INPUT' not found."
    exit 1
fi

echo "=========================================="
echo "Processing: $(basename "$INPUT")"
echo "=========================================="

# Step 1: Check for DRM
echo "Step 1 – DRM detection"
if check_drm "$INPUT"; then
    echo "  ✓ DRM detected."
    echo "Step 2 – Removing DRM"
    CLEANED_EPUB=$(remove_drm_with_calibre "$INPUT")
    if [ -z "$CLEANED_EPUB" ] || [ ! -f "$CLEANED_EPUB" ]; then
        echo "Error: DRM removal failed. Exiting."
        exit 1
    fi
else
    echo "  ✓ No DRM detected."
    CLEANED_EPUB="$INPUT"
fi

# Step 3: Strip PUA characters (always do this)
echo "Step 3 – Stripping Private Use Area (PUA) characters"
PUA_STRIPPED_EPUB=$(strip_pua_characters "$CLEANED_EPUB")
if [ -z "$PUA_STRIPPED_EPUB" ] || [ ! -f "$PUA_STRIPPED_EPUB" ]; then
    echo "Error: PUA stripping failed. Exiting."
    exit 1
fi

# Step 4: Convert to PDF
echo "Step 4 – Converting to PDF"
PDF_FILE=$(convert_to_pdf "$PUA_STRIPPED_EPUB")

echo "=========================================="
echo "All done!"
echo "  Final PDF: $PDF_FILE"
echo "  Intermediate files:"
echo "    - DRM-cleaned: $CLEANED_EPUB"
echo "    - PUA-stripped: $PUA_STRIPPED_EPUB"
echo "=========================================="