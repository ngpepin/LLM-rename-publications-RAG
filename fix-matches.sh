#!/bin/bash
# shellcheck disable=SC2004
# shellcheck disable=SC2010
# shellcheck disable=SC2034
# shellcheck disable=SC2086

# PURPOSE:
#
# Used in conjuntion with / is called by rename-using-ebooks-tools.sh
#
# - Fixes an issue with ebook-tools where the script creates a directory
#   for a matching book instead of properly renaming the source file.
#   It will move the files to the root destination directory and rename them
#   based on the directory name from which they were moved. Since the ebook-tools bug
#   results in the extension being lost, this script determines the file type based on
#   the actual structure of the file, and, failing that, the mimetype. If the file type
#   cannot be determined, it will get an .unknown extension.
#
#   Initial state due to bug:
#
#   X : the new book filename determined by ebook-tools
#   Y : the original book filename
#
#   < root destination directory >
#   └── <directory named X>
#   |   └── input
#   |       ├── <file named Y>                          # extension is lost
#   |       └── <file named Y>.meta
#   └── <directory named ...
#
#   Corrected final state:
#
#   < root destination directory >
#   └── <file named X >.pdf | .epub | .mobi | .txt      # extension is determined or defaults to 'unknown'
#   └── <file named X >.meta
#   └── <file named ...
#
# USAGE:
#  ./fix-matches.sh <directory_path>
#  <directory_path> : The path to the directory containing the directories created by ebook-tools
#
# EXAMPLE:
#  ./fix-matches.sh /path/to/ebooks
#
# NOTE:
#  - This script is intended to be run in the same environment as ebook-tools.
#  - It requires the following tools to be installed:
#    - pdftotext
#    - unzip
#    - mobi_unpack
#    - file
#

DEBUG=false
MAX_LENGTH=130 # Change this value to set a different max length for debug messages

if [ -z "$1" ]; then
    echo "Usage: $0 <directory_path>"
    exit 1
fi

target_dir="$1"

# Ensure the provided argument is a valid directory
if [ ! -d "$target_dir" ]; then
    echo "Error: '$target_dir' is not a valid directory."
    exit 1
fi

# Define colour codes
RESET="\e[0m"
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"

_msg() {
    local show=$1
    local msg="$2"
    local colour="$3"

    if [ $show = true ]; then

        local color_code="$RESET"
        local trunc_length=$((MAX_LENGTH - 3)) # Reserve space for "..."

        # If a second argument is provided, set the corresponding color
        case "$colour" in
        red) color_code="$RED" ;;
        green) color_code="$GREEN" ;;
        yellow) color_code="$YELLOW" ;;
        blue) color_code="$BLUE" ;;
        *) color_code="$RESET" ;; # Default to white (normal)
        esac

        # Truncate if message is too long
        if [ ${#msg} -gt "$MAX_LENGTH" ]; then
            msg="${msg:0:$trunc_length}..."
        fi

        # Print the message in the chosen color
        echo -e "${color_code}${msg}${RESET}"
    fi
}

debug_msg() {
    local msg="$1"
    local colour="$2"
    _msg $DEBUG "$msg" "$colour"
}

message() {
    local msg="$1"
    local colour="$2"
    _msg true "$msg" "$colour"
}

message "Fixes an issue with ebook-tools where the script creates a directory"
message "for a matching book instead of properly renaming the source file"

# Function to determine file type based on actual structure
determine_extension() {
    local in_file="$1"
    temp_dir=$(mktemp -d)

    if pdftotext "$in_file" - &>/dev/null 2>&1; then
        echo "pdf"
    elif unzip -tq "$in_file" 2>/dev/null | grep -q "mimetypeapplication/epub+zip"; then
        echo "epub"
    elif mobi_unpack "$in_file" "$temp_dir" &>/dev/null 2>&1; then
        echo "mobi"
    elif file "$in_file" 2>/dev/null | grep -q "ASCII text\|UTF-8 Unicode text"; then
        echo "txt"
    else
        # Try to determine file type using MIME info
        mime_type=$(file --mime-type -b "$in_file" 2>/dev/null)
        case "$mime_type" in
        "application/pdf") echo "pdf" ;;
        "application/epub+zip") echo "epub" ;;
        "application/x-mobipocket-ebook" | "application/octet-stream") echo "mobi" ;;
        "text/plain") echo "txt" ;;
        *) echo "unknown" ;;
        esac
    fi

    # Clean up temporary directory
    rm -rf "$temp_dir"
}

get_unique_filename() {
    local filename="$1"

    local base_name="${filename%.*}"  # Remove the last extension
    local extension="${filename##*.}" # Get the last extension
    local counter=1
    local new_filename="$filename"

    # Check if the file already exists
    if [[ -e "$filename" ]]; then
        # Extract the true basename (before the first extension)
        local true_base_name="${filename%%.*}"
        local remaining_ext="${filename#*.}"

        # Check if the true basename already contains a counter in the format (n)
        if [[ "$true_base_name" =~ \((.*)\)$ ]]; then
            # Extract the existing counter and increment it

            counter=$((${BASH_REMATCH[1]} + 1))
            true_base_name="${true_base_name%(*}" # Remove the existing counter
        fi

        # Construct the new filename with the incremented counter
        new_filename="${true_base_name}(${counter}).${remaining_ext}"

        # Recursively call the function to handle cases where the new filename also exists
        new_filename=$(get_unique_filename "$new_filename")
    fi

    echo "$new_filename"
}

# find all directories in the target directory (excluding files in target_dir)
find "$target_dir" -mindepth 1 -maxdepth 1 -type d | while read -r dir; do

    dir_no_path="${dir##*/}"

    # Skip if the directory is a special directory
    if [[ "$dir_no_path" =~ ^(Pamphlets|Corrupt|Uncertain|Failed)$ ]]; then
        debug_msg "Skipping directory:  $dir_no_path" "yellow"
        continue
    fi
    message "Processing directory:  $dir_no_path" "blue"
    # Check if there is an input directory
    if [ -d "$dir/input" ]; then
        input_dir="$dir/input"

        mapfile -t file_array < <(ls "$input_dir" | grep -vE '\.meta$|\.unknown$')

        # Check if the array is empty
        if [ ${#file_array[@]} -eq 0 ]; then
            debug_msg "No matching files found in $dir_no_path/input" "yellow"
            continue
        else
            file=""
            for i in "${!file_array[@]}"; do
                file="${file_array[$i]}"
                file_full_path="$target_dir/$dir_no_path/input/$file"
                metafile_full_path="${file_full_path}.meta"
                file_extension=$(determine_extension "$file_full_path")
                if [ "$file_extension" != "unknown" ]; then
                    break
                fi
            done
            if [ -n "$file" ]; then
                debug_msg "Found file $file of type $file_extension"
                new_file_name="$target_dir/${dir_no_path}${file_extension}"
                new_file_name="$(get_unique_filename "$new_file_name")"
                new_meta_name="${new_file_name}.meta"
                message "Renaming to $new_file_name" "green"
                message "Renaming .meta file to $new_meta_name" "green"
                mv -f "$file_full_path" "$new_file_name"
                mv -f "$metafile_full_path" "$new_meta_name"
                rm -rf "$dir" >/dev/null 2>&1
                debug_msg "------------------------------------------------------------------------------------------------------------------"
            else
                debug_msg "No matching files found in $dir_no_path/input" "yellow"
            fi
        fi
    fi
done
