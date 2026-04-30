#!/bin/bash
# shellcheck disable=SC2002
# shellcheck disable=SC1003
# shellcheck disable=SC2155
# shellcheck disable=SC2295

#######################################################################################################
# This script renames eBook files based on their content using a Language Model (LLM) API.
# It extracts metadata such as title, author, publication year, and ISBN from the content of the books.
# Supported file formats: PDF and EPUB.
#
# Dependencies:
# - jq: For parsing JSON responses from the LLM API.
# - pdftotext: For extracting text content from PDF files.
# - ebook-convert: For converting EPUB files to plain text.
# - str: For string manipulation tasks.
#
# Features:
# - Metadata extraction using LLM API.
# - Automatic renaming of eBook files based on extracted metadata.
# - Error handling and retry logic for API requests.
# - Logging of operations for debugging and tracking.
#
# Usage:
# ./rename-using-llm.sh /path/to/books
#
# Notes:
# - Ensure all dependencies are installed and available in the system PATH.
# - The script assumes that the LLM API key and endpoint are configured within the script.
# - For large collections of books, the script may take time depending on API response times.
#######################################################################################################

PROJ_DIR=""     # Replaced with project directory sourced from rename-using-llm.conf
API_ENDPOINT="" # Replaced with API endpoint sourced from rename-using-llm.conf
MODEL=""        # Model to use for LLM API requests, e.g., gpt-4o (may need to use gpt-4)

# Source the configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/rename-using-llm.conf"

INPUT_DIR="$1" # Directory containing the book files
LOG_FILE="$PROJ_DIR/logs/rename_books_$$"
LOG_FILE+="_${CURRENT_TIME}.log" # Log file for storing the output
MAX_RETRIES=1                    # Maximum number of retries for API requests
# RETRY_DELAY=4                    # Delay between retries in seconds
ORIGINALS_SUBDIR="Originals" # Directory to store copies of original files
FAILED_SUBDIR="Failed"       # Directory to store renamed files
EXTRACT_SENT_TO_LLM_LENGTH=10000 # Number of lines to extract from the text file for LLM processing

##### NO CHANGES REQUIRED BELOW THIS LINE #####

# capture current date time as YYYMMDDHHMMSS
CURRENT_TIME=$(date +"%Y%m%d%H%M%S")

# Colours
NC='\033[0m'
BRED='\033[1;91m'
BGREEN='\033[1;92m'

if [ -z "$INPUT_DIR" ]; then
    echo -e "${BRED}Error: No input directory provided.${NC}"
    echo "Usage: $0 /path/to/books"
    exit 1
fi
if [[ "$INPUT_DIR" == "." ]]; then
    INPUT_DIR=$(pwd)
fi
if [ ! -d "$INPUT_DIR" ]; then
    echo "Error: Directory '$INPUT_DIR' not found." | tee -a "$LOG_FILE"
    exit 1
fi
# Check requirements
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' is required but not installed. Install with: sudo apt install jq" | tee -a "$LOG_FILE"
    exit 1
fi
if ! command -v pdftotext &>/dev/null || ! command -v ebook-convert &>/dev/null; then
    echo "Error: Required tools 'pdftotext' or 'ebook-convert' are not installed. Install with: sudo apt install poppler-utils calibre" | tee -a "$LOG_FILE"
    exit 1
fi

mkdir -p "$PROJ_DIR/logs" >/dev/null 2>&1 # Create logs directory if it doesn't exist
touch "$LOG_FILE" >/dev/null 2>&1         # Create log file if it doesn't exist
# Only keep the last 10 most recent files
if [ "$(ls -A "$PROJ_DIR/logs")" ]; then
    find "$PROJ_DIR/logs" -type f -printf '%T+ %p\n' | sort -r | awk 'NR>10 {print $2}' | xargs rm -f >>"$LOG_FILE" 2>&1
fi

# Global variables for timing
TIME_START=0
TIME_TOTAL=0 # Cumulative seconds (float)

time_start() {
    TIME_START=$(date +%s.%4N) # Capture start time with 4 decimal places
}

###############
# This function, time_stop, calculates and logs the elapsed time since a
# predefined start time (TIME_START) and updates the total elapsed time (TIME_TOTAL).
#
# Steps performed:
# 1. Captures the current time in seconds with millisecond precision.
# 2. Computes the elapsed time since TIME_START using bc for floating-point arithmetic.
# 3. Updates the cumulative total elapsed time (TIME_TOTAL).
# 4. Converts the total elapsed time into minutes and seconds format.
# 5. Logs the elapsed time for the current operation and the cumulative total time
#    in MM:SS format to both the console and a log file (LOG_FILE).
#
# Variables:
# - TIME_START: The start time of the operation (should be set before calling this function).
# - TIME_TOTAL: The cumulative total elapsed time (should be initialized before calling this function).
# - LOG_FILE: The file where the timing information will be appended.
###############

time_stop() {

    local end_time=$(date +%s.%4N)
    local elapsed=$(echo "$end_time - $TIME_START" | bc)

    # Update total time
    TIME_TOTAL=$(echo "$TIME_TOTAL + $elapsed" | bc)

    # Convert total to MM:SS
    local total_seconds=$(printf "%.0f" "$TIME_TOTAL")
    local minutes=$((total_seconds / 60))
    local seconds=$((total_seconds % 60))

    # Print results
    printf "API Usage:  Elapsed %.4fs    Total (mins) %02d:%02d\n" "$elapsed" "$minutes" "$seconds" | tee -a "$LOG_FILE"
}

###############
# This script defines a function `clean_file_name` that processes and cleans up a given file name.
# The function performs the following operations:
# 1. Removes the prefix "Title -" or "Title-" from the file name.
# 2. Replaces newline characters with spaces.
# 3. Trims leading and trailing spaces from the file name.
# 4. Removes leading and trailing double quotes from the file name.
# 5. Replaces double quotes (`"`) within the file name with spaces.
# 6. Replaces occurrences of double asterisks (`**`) with spaces.
# 7. Collapses multiple spaces into a single space.
# 8. Ensures no leading or trailing double quotes remain after processing.
# The cleaned file name is then echoed as the output of the function.
###############

clean_file_name() {
    # Function to clean the name by removing unwanted characters
    local new_name="$1"
    new_name="${new_name#Title -}"
    new_name="${new_name#Title-}"
    new_name=$(echo "$new_name" | tr '\n' ' ')
    new_name=$(echo "$new_name" | sed 's/^ *//; s/ *$//')
    new_name=$(echo "$new_name" | sed 's/^"//; s/"$//')
    new_name=$(echo "$new_name" | str replace '"' ' ')
    new_name=$(echo "$new_name" | str replace '**' ' ' | str replace '**' ' ')
    new_name=$(echo "$new_name" | str replace '  ' ' ' | str replace '  ' ' ')
    new_name=${new_name#\"}
    new_name=${new_name%\"}
    echo "$new_name"
}

###############
# This function checks if a given response
# (passed as an argument) is valid. The function evaluates the input string
# and returns a success status (0) if the string is non-empty, not "null",
# and not "NA". Otherwise, it returns a failure status (1).
#
# Parameters:
#   $1 - The response string to validate.
#
# Returns:
#   0 - If the response is valid.
#   1 - If the response is invalid.
###############

good_response() {
    # Function to test the API response
    local new_name="$1"
    if [[ "$new_name" != "" ]] && [[ "$new_name" != "null" ]] && [[ "$new_name" != "NA" ]]; then
        return 0
    else
        return 1
    fi
}

###############
# This function, `append_index_if_duplicate`, ensures that a file path is unique by appending
# an incremental index to the file name if a file with the same name already exists.
#
# Parameters:
#   $1 - The full path of the file to check for duplicates.
#
# Behavior:
#   - Extracts the directory, file name, and extension from the input path.
#   - Strips any existing numeric suffix (e.g., "_1", "_2") from the file name.
#   - Constructs a new file path by appending an incremental numeric suffix (e.g., "_1", "_2")
#     if a file with the same name already exists in the directory.
#   - Returns the unique file path.
#
# Output:
#   - Prints the unique file path to stdout.
#
# Example:
#   Input: /path/to/file.txt
#   If /path/to/file.txt exists, the function will return /path/to/file_1.txt.
#   If /path/to/file_1.txt also exists, it will return /path/to/file_2.txt, and so on.
###############

append_index_if_duplicate() {
    # Function to rename the file if it already exists
    local in_path="$1"
    local in_fn=$(basename -- "$in_path")
    local in_dir=$(dirname "$in_path")
    local in_ext="${in_fn##*.}"
    local fn_noext="${in_fn%.*}"
    local stripped="${fn_noext%%_+([0-9])}"
    local new_name=""
    if [[ "$stripped" == "$fn_noext" ]]; then
        new_name="$fn_noext"
    else
        new_name="$stripped"
    fi
    local new_path="${in_dir}/${new_name}.${in_ext}"
    local counter=1
    while [[ -e "$new_path" ]]; do
        new_path="${in_dir}/${new_name}_${counter}.${in_ext}"
        ((counter++))
    done
    echo "$new_path"
}

# Initialize log file
echo "Rename Books Log - $(date)" >>"$LOG_FILE"
echo "API Endpoint: $API_ENDPOINT" >>"$LOG_FILE"

# Test API connection first
echo "Testing API connection..." | tee -a "$LOG_FILE"
TEST_RESPONSE=$(curl -s -X POST "$API_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d '{
        "model": "'"$MODEL"'",
        "messages": [
            {"role": "system", "content": "Test connection."},
            {"role": "user", "content": "Hello"}
        ],
        "temperature": 0
    }')
if [[ "$TEST_RESPONSE" == *"error"* ]]; then
    echo "API Connection Failed. Response: $TEST_RESPONSE" | tee -a "$LOG_FILE"
    exit 1
else
    echo "API Connection Successful" | tee -a "$LOG_FILE"
fi

echo "Renamed files will remain in place." | tee -a "$LOG_FILE"
echo "Log file: $LOG_FILE" | tee -a "$LOG_FILE"

failed_dir="$INPUT_DIR/$FAILED_SUBDIR"
failed_dir="${failed_dir//\/\//\/}"

mkdir -p "$failed_dir" # Create failed directory if it doesn't exist
echo "Failed match directory: $failed_dir" | tee -a "$LOG_FILE"

# Process files
find "$INPUT_DIR" -type f \( -name "*.pdf" -o -name "*.epub" -o -name "*.chm" -o -name "*.mobi" \) | while IFS= read -r file; do

    # Skip files in Originals/ and Failed/ subdirectories

    rel_path="${file#$INPUT_DIR}"
    rel_path="${rel_path#/}" # Remove leading slash if present
    if [[ "/$rel_path" != *"/$ORIGINALS_SUBDIR/"* ]] && [[ "/$rel_path" != *"/$FAILED_SUBDIR/"* ]]; then

        ###############
        # The following processes a list of files and attempts to extract text from them for renaming purposes.
        # It supports PDF, EPUB, and CHM file formats. Unsupported file types are skipped.
        #
        # Steps:
        # 1. Logs the start of processing for each file.
        # 2. Extracts the filename and its extension.
        # 3. Converts the file to plain text:
        #    - For PDFs, uses `pdftotext`.
        #    - For EPUB and CHM files, uses `ebook-convert`.
        #    - Skips unsupported file types with a log message.
        # 4. Checks if the text extraction was successful:
        #    - Skips the file if the resulting text file is empty.
        # 5. Processes the extracted text:
        #    - Reads the first n lines of the text.
        #    - Cleans the text by removing special characters, non-printable characters, and redundant spaces.
        #    - Limits the processed text to 26,000 characters.
        # 6. Prepares the extracted text for further processing (e.g., renaming).
        #
        # Variables:
        # - `file`: The current file being processed.
        # - `LOG_FILE`: The log file where processing details are recorded.
        # - `temp_file`: Temporary file used to store extracted text.
        # - `extracted_text`: The cleaned and processed text extracted from the file.
        # - `new_name`: Placeholder for the new name of the file (to be implemented).
        # - `to_skip`: Flag indicating whether the file should be skipped.
        ###############

        echo "-----------------------------------------------------------------------------------------------------------------------------------------------------------" | tee -a "$LOG_FILE"
        echo "Processing: $file" | tee -a "$LOG_FILE"

        filename=$(basename -- "$file")
        extension="${filename##*.}"
        # filename_noext="${filename%.*}"

        # Convert file to plain text
        temp_file=$(mktemp)
        temp_file+=".txt"
        if [[ "$extension" == "pdf" ]]; then
            pdftotext "$file" "$temp_file" >>"$LOG_FILE" 2>&1
        elif [[ "$extension" == "epub" ]] || [[ "$extension" == "chm" ]] || [[ "$extension" == "mobi" ]]; then
            ebook-convert "$file" "$temp_file" >/dev/null 2>>"$LOG_FILE"
        else
            echo -e "${BRED}SKIPPING: Unsupported file type: $file.${NC}" | tee -a "$LOG_FILE"
            rm -f "$temp_file"
            mv -f "$file" "$failed_dir/$filename" >>"$LOG_FILE" 2>&1
            continue
        fi

        # Check for empty text file and handle errors
        if [ ! -s "$temp_file" ]; then
            echo -e "${BRED}SKIPPING: Failed to extract text from: $file.${NC}" | tee -a "$LOG_FILE"
            rm -f "$temp_file"
            mv -f "$file" "$failed_dir/$filename" >>"$LOG_FILE" 2>&1
            continue
        fi

        extracted_text=$(head -n $EXTRACT_SENT_TO_LLM_LENGTH "$temp_file" | tr '"' ' ' | tr "'" " " | tr '\n' ' ' | tr '\r' ' ' | tr '\t' ' ' | tr '\\' ' ' | tr '/' ' ' | tr '$' ' ' | tr '^' ' ') 
        extracted_text=$(echo "$extracted_text" | sed "s/’/ /g" | sed 's/[^[:print:]]//g' | str replace "- -" " " | str replace '. . .' ' ' | str replace '....' ' ') 
        extracted_text=$(echo "$extracted_text" | tr -c '\40-\176' ' ' | sed 's/  */ /g' | sed 's/  */ /g' | str replace " ... " "." | str replace ": )" " " | str replace ") :" " " | str replace ",," " " | str replace ", . ," " " | str replace ", ," " " | str replace ". ." " " | str replace "  " " " | str replace "  " " " | str replace "  " " ") 
        extracted_text="${extracted_text:0:26000}"
        extracted_text=${extracted_text#\"}
        extracted_text=${extracted_text%\"}
        # echo "Extracted text: $extracted_text"
        new_name=""
        to_skip=true
        check_blank=$(echo "$extracted_text" | tr -d ' ') 
        if [ -n "$check_blank" ]; then

            for ((retry = 1; retry <= MAX_RETRIES; retry++)); do

                ###############
                # The following interacts with an API (OpenAI API based model) to extract and format metadata
                # for eBooks based on provided text. The script performs the following steps:
                #
                # 1. Constructs a cURL command to send a POST request to the API endpoint.
                #    - The request includes a JSON payload specifying the model, system instructions, and user prompt.
                #    - The system instructions define the role of the model as a metadata extractor.
                #    - The user prompt provides the text to analyze and specifies the desired output format.
                #
                # 2. Logs the constructed command to a log file for debugging purposes.
                #
                # 3. Executes the API request and captures the response in a temporary file.
                #    - Measures the time taken for the API call using `time_start` and `time_stop` functions.
                #
                # 4. Processes the API response:
                #    - Reads the response from the temporary file and removes non-printable characters.
                #    - Logs the raw API response for debugging.
                #    - Checks if the response contains an error message.
                #      - If an error is detected, logs the error and skips further processing.
                #
                # 5. Parses the API response to extract the formatted metadata:
                #    - Attempts to extract the metadata using `jq` to parse the JSON response.
                #    - Cleans the extracted metadata using the `clean_file_name` function.
                #    - Validates the parsed metadata using the `good_response` function.
                #    - If the initial parsing fails, attempts to extract the metadata using `sed` as a fallback.
                #
                # 6. Logs the parsed metadata and determines whether to proceed or retry based on validation.
                #
                # 7. Cleans up temporary files and handles retries or skips as necessary.
                #
                # Notes:
                # - The script enforces strict formatting for the metadata output.
                # - It includes error handling for API errors and invalid responses.
                # - The script supports retries but currently has the retry delay commented out.
                # - The API response is expected to be in JSON format, and the metadata is extracted from the "content" field.
                ###############

                cmd='curl -s -X POST '
                cmd+="$API_ENDPOINT "
                cmd+='-H "Content-Type: application/json" '
                cmd+="-d '{ \"model\": \"$MODEL\", \"messages\": [{\"role\": \"system\", \"content\": "
                cmd+="\"You are a metadata extractor. Return ONLY the formatted book details.\""
                cmd+='},{ "role": "user", "content": "Extract the book title, volume(s), author(s), publication year, and ISBN (if available) from the following text:\n\"'
                cmd+="$extracted_text"
                cmd+='\"\nIf you cannot find any of these explicitly, examine the content to see if you can identify the publication by some other means. '
                cmd+='Return ONLY in this format: \"Title - Author(s) (Year) [ISBN]\". Only return ONE match, the most likely. Do NOT return more than one. '
                cmd+='If you are unsure then return NA. If you do not obtain an ISBN by inspecting this text extract, please perform a web lookup '
                cmd+='to try to determine it indirectly from other sources. If the information is not in English, French or Spanish, please perform a translation into English. '
				cmd+='Pay special attention to volume numbers (if any), being sure to include the specific volume number of a series in the title. Do not return all volume names, just the one you have identified. '
				cmd+='If the book has more than three authors, only return the first three followed by et al. '
				cmd+='Please ensure that you return only characters that are legal in a Linux filename. "'
                cmd+='}], "temperature": 0.3, "max_tokens": 90000 '
                cmd+="}'"
                echo "Executing command: $cmd" >>"$LOG_FILE"

                temp_response_file=$(mktemp) 
                time_start
                eval "$cmd" >"$temp_response_file"
                time_stop

                LLM_RESPONSE="$(cat "$temp_response_file" | tr -c '\40-\176' ' ')"
                rm -f "$temp_response_file" >/dev/null 2>&1

                # Log the response
                echo "API Response (Attempt $retry): $LLM_RESPONSE" >>"$LOG_FILE"
                # Check for errors in the API response
                if [[ "$LLM_RESPONSE" == *"error"* ]]; then
                    echo -e "${BRED}SKIPPING: API Error on attempt $retry: $LLM_RESPONSE.${NC}" >>"$LOG_FILE"
                    # mv -f "$file" "$failed_dir/$file" >>"$LOG_FILE" 2>&1
                    # sleep $RETRY_DELAY
                else
                    # Parse the response
                    new_name=$(echo "$LLM_RESPONSE" | jq -r '.choices[0].message.content')
                    new_name=$(clean_file_name "$new_name")
                    echo "Parsed name: $new_name" >>"$LOG_FILE"
                    if good_response "$new_name"; then
                        to_skip=false
                        break
                    else
                        # Try to extract the portion between "content":"\" and \", using sed
                        new_name=$(echo "$LLM_RESPONSE" | sed -n 's/.*"content":"\\"\(.*\)\\"".*/\1/p')
                        new_name=$(clean_file_name "$new_name")
                        echo "Sed output: $new_name" >>"$LOG_FILE"
                        if good_response "$new_name"; then
                            to_skip=false
                            break
                            #else
                            #echo -e "${BRED}SKIPPING: Invalid response on attempt $retry.${NC}" >>"$LOG_FILE"
                        #    sleep $RETRY_DELAY
                        fi

                    fi
                fi
            done
        fi

        if [ "$to_skip" = true ]; then
            echo "SKIPPING: No match found." | tee -a "$LOG_FILE"
            rm -f "$temp_file"
            mv -f "$file" "$failed_dir/$filename" >>"$LOG_FILE" 2>&1
            continue
        else
            ###############
            # The following processes and renames files, with special handling for `.chm` files.
            # It performs the following steps:
            # 1. Cleans the new file name using the `clean_file_name` function.
            # 2. Extracts the old file's name and path for reference.
            # 3. Checks the file extension:
            #    - If the file is a `.chm` file:
            #      - Converts it to a `.pdf` file using `ebook-convert`.
            #      - Deletes the original `.chm` file after conversion.
            #    - For other file types:
            #      - Renames the file to the cleaned name with its original extension.
            # 4. Handles file name collisions by appending an index to the new name if necessary,
            #    using the `append_index_if_duplicate` function.
            # 5. Logs all operations to a log file (`$LOG_FILE`) and provides user feedback:
            #    - Indicates when a file is renamed or converted.
            #    - Notes when no renaming is required or when an index is added to avoid collisions.
            ###############

            new_name=$(clean_file_name "$new_name")
            old_file="$file"
            old_filepath=$(dirname "$file")
            old_filename=$(basename -- "$file")
            originals_dir="$old_filepath/$ORIGINALS_SUBDIR"
            archived_original="$originals_dir/$old_filename"

            # Rename (/convert) the file and clean up
            if [[ "$extension" == "chm" ]] || [[ "$extension" == "mobi" ]]; then

                new_filename="${new_name}.pdf"
                new_path="$old_filepath/$new_filename"
                final_path=$(append_index_if_duplicate "$new_path")
                final_name=$(basename -- "$final_path")

                echo -e "${BGREEN}RENAMING & CONVERTING TO: $final_name.${NC}" | tee -a "$LOG_FILE"
                mkdir -p "$originals_dir" >>"$LOG_FILE" 2>&1
                archived_original=$(append_index_if_duplicate "$archived_original")
                if ! cp -fp "$old_file" "$archived_original" >>"$LOG_FILE" 2>&1; then
                    echo -e "${BRED}SKIPPING: Failed to archive original file before converting: $old_file.${NC}" | tee -a "$LOG_FILE"
                    rm -f "$temp_file"
                    continue
                fi
                ebook-convert "$old_file" "$final_path" >>"$LOG_FILE" 2>&1
                rm -f "$old_file" >>"$LOG_FILE" 2>&1 # delete old .chm file
            else
                new_filename="${new_name}.${extension}"
                new_path="$old_filepath/$new_filename"
                final_path=$(append_index_if_duplicate "$new_path")
                final_name=$(basename -- "$final_path")

                if [[ "$new_filename" != "$old_filename" ]]; then
                    echo -e "${BGREEN}RENAMING TO: $final_name.${NC}" | tee -a "$LOG_FILE"
                else
                    if [[ "$final_name" != "$new_filename" ]]; then
                        echo -e "${BGREEN}NAME UNCHANGED; ADDING INDEX TO AVOID COLLISION: $final_name.${NC}" | tee -a "$LOG_FILE"
                    else
                        echo -e "${BGREEN}NAME UNCHANGED; NO RENAMING REQUIRED.${NC}" | tee -a "$LOG_FILE"
                    fi
                fi
                mkdir -p "$originals_dir" >>"$LOG_FILE" 2>&1
                archived_original=$(append_index_if_duplicate "$archived_original")
                if ! cp -fp "$old_file" "$archived_original" >>"$LOG_FILE" 2>&1; then
                    echo -e "${BRED}SKIPPING: Failed to archive original file before renaming: $old_file.${NC}" | tee -a "$LOG_FILE"
                    rm -f "$temp_file"
                    continue
                fi
                if [[ "$old_file" != "$final_path" ]]; then
                    mv -f "$old_file" "$final_path" >>"$LOG_FILE" 2>&1
                fi
            fi
        fi
        rm -f "$temp_file"
    else
        echo -e "SKIPPING: Already processed: $file." | tee -a "$LOG_FILE"
    fi

done

echo "-------------------------------------------------------------------------------------------------------" | tee -a "$LOG_FILE"
echo "Processing complete. See details in $LOG_FILE"
