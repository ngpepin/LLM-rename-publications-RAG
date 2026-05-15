#!/bin/bash

# Function to check for DRM by looking for an encryption.xml file
# True DRM will have an entry with a non-obfuscation algorithm.
# Based on: https://www.w3.org/publishing/epub3/epub-ocf.html#sec-container-metainf-encryption.xml
check_drm() {
    local epub_file="$1"
    local temp_dir

    # Create a secure, temporary directory for extraction
    temp_dir=$(mktemp -d)
    if ! unzip -q "$epub_file" "META-INF/encryption.xml" -d "$temp_dir" 2>/dev/null; then
        rm -rf "$temp_dir"
        return 1 # No encryption.xml file -> No DRM
    fi

    # Check if the encryption.xml file contains a non-obfuscation algorithm
    # The obfuscation algorithm URI is: http://www.idpf.org/2008/embedding
    if grep -q "EncryptionMethod.*Algorithm=\"[^\"]*\"[^>]*>" "$temp_dir/META-INF/encryption.xml" | \
       grep -qv "http://www.idpf.org/2008/embedding"; then
        rm -rf "$temp_dir"
        return 0 # True DRM found
    else
        rm -rf "$temp_dir"
        return 1 # Only font obfuscation found
    fi
}

# --- Main Script ---

# Check if an EPUB file was provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <epub_file>"
    exit 1
fi

input_file="$1"
file_dir=$(dirname "$input_file")
base_name=$(basename "$input_file" .epub)
output_file="${file_dir}/${base_name}_noDRM.epub"

# 1. Verify the file exists
if [ ! -f "$input_file" ]; then
    echo "Error: File '$input_file' not found."
    exit 1
fi

# 2. Check if the file has DRM
echo "Checking for DRM in '$input_file'..."
if check_drm "$input_file"; then
    echo "DRM detected. Attempting to remove it..."

    # Create a temporary Calibre library for processing
    temp_library=$(mktemp -d)

    # 3. Add the EPUB to the temporary Calibre library
    # The DeDRM plugin will automatically trigger and remove the DRM at this stage.
    if calibredb add --with-library="$temp_library" "$input_file" >/dev/null 2>&1; then

        # 4. Locate the DRM-cleaned EPUB in the library's structure
        # The DeDRM plugin leaves the processed file in the library folder.
        # It is typically the only EPUB file in the new library's author/title subfolder.
        cleaned_file=$(find "$temp_library" -name "*.epub" -type f | head -n 1)

        if [ -n "$cleaned_file" ] && [ -f "$cleaned_file" ]; then
            # Copy the processed file to the destination, preserving the original
            cp "$cleaned_file" "$output_file"
            echo "Success: DRM removed and saved as '$output_file'."
        else
            echo "Error: Could not locate the processed file in the temporary library."
            rm -rf "$temp_library"
            exit 1
        fi
    else
        echo "Error: calibredb failed to add the file. DRM removal may not be possible."
        rm -rf "$temp_library"
        exit 1
    fi

    # Clean up the temporary library
    rm -rf "$temp_library"
else
    echo "No DRM detected. The file is already DRM-free."
fi

exit 0