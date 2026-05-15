#!/bin/bash
# shellcheck disable=SC2086
# shellcheck disable=SC2034
#
# rename-using-ebooks-tools.sh
#
# PURPOSE:
# This script renames and organizes ebooks in a directory. It uses the Docker image 'didc/ebook-tools:latest' to
# perform the operations (a fork of Ned Andreev's excellent ebook-tools). The script will build the Docker image if it does not exist, and then run the container
# to perform the operations.
#
# See: https://github.com/na--/ebook-tools
#
# USAGE:
# rename-using-ebooks-tools.sh [-c | --config <config_file>] [-i | --input <input_dir>] [-o | --output <output_dir>] [-f | --fresh] [-d | --debug] [-h | --help]
#
# Options:
#   -c, --config        Specify the configuration file
#   -i, --input         Specify the input directory
#   -o, --output        Specify the output directory
#   -f, --fresh         Re-download the Docker image
#   -d, --debug         Run in debug mode
#   -h, --help          Display this help message
#
# DEPENDENCIES:
#   - jq
#   - docker
#
# Uses scripts:
#   - fix-matches.sh
#
#     * The script fix-matches.sh is used to fix an issue with ebook-tools where organize-ebooks.sh and lib.sh
#       create a directory for a matching book instead of properly renaming the source file using the descriptive text.
#     * The script moves the content and .meta files to the root destination directory and renames them based on the
#       directory name from which they came. It also renames the ".meta" file created by ebook-tools.
#     * Since the ebook-tools bug results in the source file extension being lost, this script determines
#       the file type (pdf, epub, mobi or txt) based on the actual structure of the file, and, failing that, its mimetype.
#       If the file type cannot be determined, the file is given an '.unknown' extension.
#
# CONFIGURATION:
#
#    - Expects the lightly modified ebook-tools scripts organize-ebooks.sh and lib.sh to be in the same directory
#      as the script as they are bind-mounted into the Docker container.
#
#    - Uses a JSON configuration file to set the options for the script. The default configuration file is
#      'config.json' in the same directory as the script. The configuration file is structured as follows:
#
# {
#   "docker": {
#     "mounts": {
#       "input": "input",
#       "output": "output",
#       "corrupt": "corrupt",
#       "pamphlets": "pamphlets",
#       "uncertain": "uncertain",
#       "failed": "failed"
#     },
#     "dirs": {
#       "input_home": "/my-input-home",     # better to just pass in the directory with '-i' option
#       "input": "",
#       "output_home": "/my-output-home",   # better to just pass in the directory with '-o' option
#       "output": "",
#       "corrupt": "/Corrupt",
#       "pamphlets": "/Pamphlets",
#       "uncertain": "/Uncertain",
#       "failed": "/Failed"
#     },
#     "image": "didc/ebook-tools:latest",
#     "dockerfile": "...",
#     "remove_container": true
#   },
#   "script_general": {
#     "verbose": false,
#     "keep_metadata": true,
#     "corruption_check_only": false,
#     "input_extensions": "^(7z|bz2|chm|arj|cab|gz|tgz|gzip|zip|rar|xz|tar|epub|docx|odt|ods|cbr|cbz|maff|iso)$",
#     "output_format": ""   # not implemented
#   },
#   "isbn": {
#     "metadata_fetch_order": "Goodreads,Amazon.com,Google,ISBNDB,WorldCat xISBN,OZON.ru",
#     "reorder_text_to_find_isbn": "true, 400, 50", # not implemented
#     "organize_without_isbn": true,
#     "without-isbn-sources": "Goodreads,Amazon.com,Google"
#   },
#   "ocr": {
#     "enabled": true,
#     "lang": "eng",
#     "only_first_last_pages": "7,3"
#   }
# }
#
# Version: 1.0
# Author: N. Pepin
# 2025-02
#

# Capture CLI arguments
ARGUMENTS=("$@")

if [[ "$#" -eq 0 ]]; then
    message "No arguments provided. Use -h or --help for usage information." "red"
    exit 1
fi

# Change to
PROJECT_DIR="" # Sourced from rename-using-ebooks-tools.conf
OUTPUT_DIR_DEF=""
ORIGINALS_SUBDIR="Originals"

# Source the configuration file
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/rename-using-ebooks-tools.conf"

FIX_SCRIPT="$PROJECT_DIR/fix-matches.sh"
CONFIG_FILE="$PROJECT_DIR/config.json"
RET_DIR=$(pwd)

ran_docker=false

CURRENT_TREE=""
set_config_tree_pos() {
    CURRENT_TREE="$1"
}
# Function to parse JSON and extract values
get_config_value() {
    local subkey=$1
    local key="${CURRENT_TREE}${subkey}"
    jq -e -r "$key // \"\"" "$CONFIG_FILE" 2>/dev/null || echo ""
}

get_unique_path() {
    local requested_path="$1"
    local dir_path
    local filename
    local extension=""
    local basename_noext=""
    local candidate_path=""
    local counter=1

    dir_path=$(dirname "$requested_path")
    filename=$(basename "$requested_path")

    if [[ "$filename" == *.* ]]; then
        extension=".${filename##*.}"
        basename_noext="${filename%.*}"
    else
        basename_noext="$filename"
    fi

    candidate_path="$requested_path"
    while [[ -e "$candidate_path" ]]; do
        candidate_path="$dir_path/${basename_noext}_$counter$extension"
        counter=$((counter + 1))
    done

    echo "$candidate_path"
}

NC='\e[39m'
LAST_COLOUR="$NC"
# shellcheck disable=SC2034
message() {
    local message="$1"
    local request_colour="$2"
    local sustain="$3"

    local BLUE='\e[94m'
    local RED='\e[91m'
    local YELLOW='\e[93m'
    local GREEN='\e[92m'
    local MAJENTA='\e[95m'
    local GRAY='\e[90m'
    local ITALICS='\e[3m'

    local sustain_colour=false
    local use_style=""
    local use_colour=""
    local end_message="$NC"

    if [ "$message" = "reset" ]; then
        LAST_COLOUR="$NC"
        echo -e "$NC"
        return
    fi

    if [ -n "$sustain" ]; then
        sustain=$(echo "$sustain" | tr '[:upper:]' '[:lower:]')
        if [ "$sustain" = "true" ]; then
            sustain_colour=true
        elif [ "$sustain" = "italics" ]; then
            use_style="$ITALICS"
        fi
    fi

    if [ -z "$request_colour" ]; then
        use_colour="$LAST_COLOUR"
    elif [ -n "$use_style" ]; then
        use_colour="$NC"
    else
        request_colour=$(echo "$request_colour" | tr '[:upper:]' '[:lower:]')
        case $request_colour in
        b | blue)
            use_colour="$BLUE"
            if [ $sustain_colour = true ]; then
                LAST_COLOUR="$BLUE"
            else
                LAST_COLOUR="$NC"
            fi
            ;;
        r | red)
            use_colour="$RED"
            if [ $sustain_colour = true ]; then
                LAST_COLOUR="$RED"
            else
                LAST_COLOUR="$NC"
            fi
            ;;
        g | green)
            use_colour="$GREEN"
            if [ $sustain_colour = true ]; then
                LAST_COLOUR="$GREEN"
            else
                LAST_COLOUR="$NC"
            fi
            ;;
        y | yellow)
            use_colour="$BLUE"
            if [ $sustain_colour = true ]; then
                LAST_COLOUR="$BLUE"
            else
                LAST_COLOUR="$NC"
            fi
            ;;
        m | magenta)
            use_colour="$MAJENTA"
            if [ $sustain_colour = true ]; then
                LAST_COLOUR="$MAJENTA"
            else
                LAST_COLOUR="$NC"
            fi
            ;;
        gr | gray)
            use_colour="$GRAY"
            if [ $sustain_colour = true ]; then
                LAST_COLOUR="$GRAY"
            else
                LAST_COLOUR="$NC"
            fi
            ;;
        i | italics)
            use_style="$ITALICS"
            ;;
        reset)
            use_colour="$LAST_COLOUR"
            LAST_COLOUR="$NC"
            sustain_colour=false
            ;;
        *)
            use_colour="$NC"
            ;;
        esac
    fi

    if [ $sustain_colour = true ]; then
        end_message=""
    else
        end_message="$NC"
    fi

    echo -e "${use_colour}${use_style}$message${end_message}"

}

RE_DOWNLOAD_IMAGE=false
INPUT_HOME_DIR=""
OUTPUT_HOME_DIR=""
NEW_CONFIG_FILE=""
DEBUG=false
single_dir_provided=false

# =====================================================================================================================
# The following:
#
# 1. Checks the number of arguments passed to the script:
#    - If only one argument is provided, it is assumed to be the input directory.
#    - If the argument is ".", the current working directory is used as the input directory.
# 2. Verifies the existence of the input directory:
#    - If the input directory does not exist, it constructs an output directory path
#      by appending "/output" to the parent directory of the input directory.
# 3. Ensures the output directory exists:
#    - If the output directory does not exist, it creates the directory using `sudo mkdir -p`.
# 4. Sets a flag (`single_dir_provided`) to indicate that only a single directory was provided.
#
# If multiple arguments have been provided or the single directory flag is not set, the script enters a loop
# to parse the command line arguments:
#
# Options:
#   -d, --debug         Enable debug mode for detailed logging.
#   -f, --fresh         Re-download the Docker image used by the script.
#   -h, --help          Display usage information and exit.
#   -c, --config        Specify the path to a custom configuration file.
#   -i, --input         Specify the input directory containing files to process.
#   -o, --output        Specify the output directory for processed files.
# =====================================================================================================================

if [ "$#" -eq 1 ]; then
    # check if first character is '-'
    only_arg="$1"

    if [[ "$only_arg" != -* ]]; then

        message "Only one argument provided, it will be assumed to be the input directory." "blue"

        if [ "$only_arg" = "." ]; then
            INPUT_HOME_DIR="$(pwd)"
        else
            # determine the real path of the input directory
            INPUT_HOME_DIR="$(realpath "$only_arg")"
        fi

        INPUT_HOME_DIR="${INPUT_HOME_DIR%/}"

        # check that the input directory exists
        if [ -d "$INPUT_HOME_DIR" ]; then
            OUTPUT_HOME_DIR="$INPUT_HOME_DIR/output"

            # check that the output directory exists
            if [ ! -d "$OUTPUT_HOME_DIR" ]; then
                sudo mkdir -p "$OUTPUT_HOME_DIR" >/dev/null 2>&1
            fi

            single_dir_provided=true
            message "Output directory: $OUTPUT_HOME_DIR" "blue"
        else
            message "Input directory does not exist: $INPUT_HOME_DIR" "yellow"
        fi
    fi
fi

if [ "$single_dir_provided" = false ]; then
    j=0
    skip=false
    for i in "${ARGUMENTS[@]}"; do
        j=$((j + 1))
        if [ $skip = true ]; then
            skip=false
        else
            case $i in
            -d | --debug)
                DEBUG=true
                shift
                ;;
            -f | --fresh)
                RE_DOWNLOAD_IMAGE=true
                shift
                ;;
            -h | --help)
                message "Usage: $0 [-c | --config <config_file>] [-i | --input <input_dir>] [-o | --output <output_dir>] [-f | --fresh] [-d | --debug] [-h | --help]" "blue" true
                message "Options:"
                message "  -c, --config        Specify the configuration file"
                message "  -i, --input         Specify the input directory"
                message "  -o, --output        Specify the output directory"
                message "  -f, --fresh         Re-download the Docker image"
                message "  -d, --debug         Run in debug mode"
                message "  -h, --help          Display this help message" "reset"
                exit 0
                ;;
            -c | --config)
                NEW_CONFIG_FILE="${ARGUMENTS[j]}"
                skip=true
                ;;
            -i | --input)
                INPUT_HOME_DIR="${ARGUMENTS[j]}"
                skip=true
                ;;
            -o | --output)
                OUTPUT_HOME_DIR="${ARGUMENTS[j]}"
                skip=true
                ;;
            *)
                # unknown option
                ;;
            esac
        fi
    done

    if [ "$NEW_CONFIG_FILE" != "" ]; then
        if [ ! -d "$NEW_CONFIG_FILE" ]; then
            message "Configuration file does not exist, reverting to default: $CONFIG_FILE" "yellow"

        else
            CONFIG_FILE="$NEW_CONFIG_FILE"
        fi
    fi
fi

set_config_tree_pos ".docker.dirs"
if [[ "$INPUT_HOME_DIR" == "" ]]; then
    INPUT_HOME_DIR=$(get_config_value ".input_home")
fi
if [[ "$OUTPUT_HOME_DIR" == "" ]]; then
    OUTPUT_HOME_DIR=$(get_config_value ".output_home")
fi

# Function to cleanup docker containers
cleanup_docker() {
    cd "$PROJECT_DIR" || exit >/dev/null 2>&1

    if [[ "$DOCKER_IMAGE" == "" ]]; then
        IMAGE_NAME="didc/ebook-tools:latest"
    else
        IMAGE_NAME="$DOCKER_IMAGE"
    fi
    CONTAINERS=$(docker ps -a --filter "ancestor=$IMAGE_NAME" -q)
    if [ -n "$CONTAINERS" ]; then
        docker stop $CONTAINERS >/dev/null 2>&1
        docker rm $CONTAINERS
        for CONTAINER in $CONTAINERS; do
            VOLUMES=$(docker inspect -f '{{range .Mounts}}{{if .Name}}{{.Name}}{{end}}{{end}}' $CONTAINER)
            if [ -n "$VOLUMES" ]; then
                docker volume rm $VOLUMES >/dev/null 2>&1
            fi
        done

    fi
}

# Function to cleanup and exit
# shellcheck disable=SC2317
cleanup() {
    #  message "Script interupted." "red"

    if [ $ran_docker = true ]; then
        #      message "Cleaning up docker artefacts before quitting..." "red"
        cleanup_docker
    fi
    # message "Quitting..." "red"
    # message "reset"
    exit 1
}

# Trap SIGINT (Ctrl-C) and EXIT signals to trigger cleanup
trap cleanup SIGINT EXIT

# =====================================================================================================================
# READ JSON CONFIGURATION FILE
# ---------------------------------------------------------------------------------------------------------------------
# Docker settings
# ---------------------------------------------------------------------------------------------------------------------
set_config_tree_pos ".docker"
DOCKER_IMAGE=$(get_config_value ".image")
REMOVE_CONTAINER=$(get_config_value ".remove_container")
DOCKER_FILE_PATH=$(get_config_value ".dockerfile")
if [ -z "$DOCKER_FILE_PATH" ]; then
    DOCKER_FILE_PATH="$DOCKERFILE_PATH_DEF"
fi
# ---------------------------------------------------------------------------------------------------------------------
# Mount points
# ---------------------------------------------------------------------------------------------------------------------
set_config_tree_pos ".docker.mounts"
INPUT_MOUNT_POINT=$(get_config_value ".input")
OUTPUT_MOUNT_POINT=$(get_config_value ".output")
CORRUPT_MOUNT_POINT=$(get_config_value ".corrupt")
FAILED_MOUNT_POINT=$(get_config_value ".failed")
UNCERTAIN_MOUNT_POINT=$(get_config_value ".uncertain")
PAMPHLETS_MOUNT_POINT=$(get_config_value ".pamphlets")
# ---------------------------------------------------------------------------------------------------------------------
# Mapped directories on host
# ---------------------------------------------------------------------------------------------------------------------
set_config_tree_pos ".docker.dirs"
INPUT_DIR="$INPUT_HOME_DIR$(get_config_value ".input")"
OUTPUT_DIR="$OUTPUT_HOME_DIR$(get_config_value ".output")"
if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="$OUTPUT_DIR_DEF"
fi
CORRUPT_DIR="$OUTPUT_HOME_DIR$(get_config_value ".corrupt")"
FAILED_DIR="$OUTPUT_HOME_DIR$(get_config_value ".failed")"
UNCERTAIN_DIR="$OUTPUT_HOME_DIR$(get_config_value ".uncertain")"
PAMPHLETS_DIR="$OUTPUT_HOME_DIR$(get_config_value ".pamphlets")"
# ---------------------------------------------------------------------------------------------------------------------
# General Script options
# ---------------------------------------------------------------------------------------------------------------------
set_config_tree_pos ".script_general"
KEEP_METADATA=$(get_config_value ".keep_metadata")
if [ $DEBUG = true ]; then
    VERBOSE=true
else
    VERBOSE=$(get_config_value ".verbose")
fi
CORRUPTION_CHECK_ONLY=$(get_config_value ".corruption_check_only")
OUTPUT_FORMAT=$(get_config_value ".output_format")
INPUT_EXTENSIONS=$(get_config_value ".input_extensions")
# ---------------------------------------------------------------------------------------------------------------------
# ISBN options
# ---------------------------------------------------------------------------------------------------------------------
set_config_tree_pos ".isbn"
# REORDER_TEXT=$(get_config_value ".reorder_text_to_find_isbn")
ISBN_METADATA_FETCH_ORDER=$(get_config_value ".metadata_fetch_order")
ORGANIZE_WITHOUT_ISBN=$(get_config_value ".organize_without_isbn")
WITHOUT_ISBN_SOURCES=$(get_config_value ".without_isbn_sources")
# ---------------------------------------------------------------------------------------------------------------------
# OCR options
# ---------------------------------------------------------------------------------------------------------------------
set_config_tree_pos ".ocr"
OCR_ENABLED=$(get_config_value ".enabled")
OCR_LANG=$(get_config_value ".lang")
OCR_FIRST_LAST=$(get_config_value ".only_first_last_pages")
# ---------------------------------------------------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------------------------------------------------
# DEF_OUTPUT_FORMAT="${d[AUTHORS]// & /, } - ${d[SERIES]:+[${d[SERIES]}] - }${d[TITLE]/:/ -}${d[PUBLISHED]:+ (${d[PUBLISHED]%%-*})}${d[ISBN]:+ [${d[ISBN]}]}.${d[EXT]}"
# "output_format": "${d[AUTHORS]// & /, } - ${d[SERIES]:+[${d[SERIES]}] - }${d[TITLE]/:/ -}${d[PUBLISHED]:+ (${d[PUBLISHED]%%-*})}${d[ISBN]:+ [${d[ISBN]}]}.${d[EXT]}"
# '"${d[TITLE]//:/ -}${d[AUTHORS]// & /, } - ${d[SERIES]:+[${d[SERIES]//:/ -}] - }${d[PUBLISHED]:+ (${d[PUBLISHED]%%-*})}${d[ISBN]:+ [${d[ISBN]}]}.${d[EXT]}"'
DEF_OUTPUT_FORMAT=""
DEF_ISBN_METADATA_FETCH_ORDER="Goodreads,Amazon.com,Google,ISBNDB,WorldCat xISBN,OZON.ru"
DEF_WITHOUT_ISBN_SOURCES="Goodreads,Amazon.com,Google"
DEF_INPUT_EXTENSIONS="^(7z|bz2|chm|arj|cab|gz|tgz|gzip|zip|rar|xz|tar|epub|docx|odt|ods|cbr|cbz|maff|iso)$"
# shellcheck disable=SC2034
DEF_REORDER_TEXT="400, 50"
DEF_DOCKERFILE_PATH="$RET_DIR/Dockerfile"

if [ $DEBUG = true ]; then
    echo "DOCKER_IMAGE:                   $DOCKER_IMAGE"
    echo "REMOVE_CONTAINER:               $REMOVE_CONTAINER"
    echo "DOCKER_FILE_PATH:               $DOCKER_FILE_PATH"
    echo "INPUT_MOUNT_POINT:              $INPUT_MOUNT_POINT"
    echo "OUTPUT_MOUNT_POINT:             $OUTPUT_MOUNT_POINT"
    echo "CORRUPT_MOUNT_POINT:            $CORRUPT_MOUNT_POINT"
    echo "UNCERTAIN_MOUNT_POINT:          $UNCERTAIN_MOUNT_POINT"
    echo "PAMPHLETS_MOUNT_POINT:          $PAMPHLETS_MOUNT_POINT"
    echo "INPUT_HOME:                     $INPUT_HOME_DIR"
    echo "INPUT_DIR:                      $INPUT_DIR"
    echo "OUTPUT_HOME:                    $OUTPUT_HOME_DIR"
    echo "OUTPUT_DIR:                     $OUTPUT_DIR"
    echo "CORRUPT_DIR:                    $CORRUPT_DIR"
    echo "UNCERTAIN_DIR:                  $UNCERTAIN_DIR"
    echo "PAMPHLETS_DIR:                  $PAMPHLETS_DIR"
    echo "KEEP_METADATA:                  $KEEP_METADATA"
    echo "VERBOSE:                        $VERBOSE"
    echo "CORRUPTION_CHECK_ONLY:          $CORRUPTION_CHECK_ONLY"
    echo "OUTPUT_FORMAT:                  $OUTPUT_FORMAT"
    echo "INPUT_EXTENSIONS:               $INPUT_EXTENSIONS"
    echo "ISBN_METADATA_FETCH_ORDER:      $ISBN_METADATA_FETCH_ORDER"
    echo "ORGANIZE_WITHOUT_ISBN:          $ORGANIZE_WITHOUT_ISBN"
    echo "WITHOUT_ISBN_SOURCES:           $WITHOUT_ISBN_SOURCES"
    echo "OCR_ENABLED:                    $OCR_ENABLED"
    echo "OCR_LANG:                       $OCR_LANG"
    echo "OCR_FIRST_LAST:                 $OCR_FIRST_LAST"
fi

# =====================================================================================================================
# VALIDATE DIRECTORIES
# ---------------------------------------------------------------------------------------------------------------------
if [ ! -d "$INPUT_DIR" ]; then
    message "Input directory does not exist: $INPUT_DIR ; creating it..." "yellow"
    sudo mkdir -p "$INPUT_DIR"
fi
if [ ! -d "$OUTPUT_DIR" ]; then
    message "Output directory does not exist: $OUTPUT_DIR ; creating it..." "yellow"
    sudo mkdir -p "$OUTPUT_DIR"
fi
if [ "$CORRUPT_MOUNT_POINT" != "" ] && [ ! -d "$CORRUPT_DIR" ]; then
    message "Corrupt directory does not exist: $CORRUPT_DIR ; creating it..." "yellow"
    sudo mkdir -p "$CORRUPT_DIR"
fi
if [ "$UNCERTAIN_MOUNT_POINT" != "" ] && [ ! -d "$UNCERTAIN_DIR" ]; then
    message "Uncertain directory does not exist: $UNCERTAIN_DIR ; creating it..." "yellow"
    sudo mkdir -p "$UNCERTAIN_DIR"
fi
if [ "$PAMPHLETS_MOUNT_POINT" != "" ] && [ ! -d "$PAMPHLETS_DIR" ]; then
    message "Pamphlets directory does not exist: $PAMPHLETS_DIR ; creating it..." "yellow"
    sudo mkdir -p "$PAMPHLETS_DIR"
fi
if [ "$FAILED_MOUNT_POINT" != "" ] && [ ! -d "$FAILED_DIR" ]; then
    message "Corrupt directory does not exist: $FAILED_DIR ; creating it..." "yellow"
    sudo mkdir -p "$FAILED_DIR"
fi

mapfile -d '' -t ORIGINAL_INPUT_FILES < <(find "$INPUT_DIR" -maxdepth 1 -type f -print0)
OUTPUT_STAGING_DIR=$(mktemp -d "$OUTPUT_DIR/staging.XXXXXX")

# =====================================================================================================================
# DOCKER COMMANDS AND OPTIONS
# ---------------------------------------------------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------------------------------------------------
cd "$PROJECT_DIR" || exit >/dev/null 2>&1
message "Cleaning up previous containers..." "blue"
cleanup_docker
# If requested, remove the image itself a pull again
if [ $RE_DOWNLOAD_IMAGE = true ]; then
    message "(Re-)downloading Docker image '$IMAGE_NAME'..." "blue"
    docker rmi "$IMAGE_NAME" >/dev/null 2>&1
    docker pull "$IMAGE_NAME"
fi

# ---------------------------------------------------------------------------------------------------------------------
# Build container
# ---------------------------------------------------------------------------------------------------------------------
message "---------------------------------------------------------------------------------------------------------------------" "blue"
RANDOM_HEX=$(openssl rand -hex 6) # 6 bytes = 12 hex characters
CONTAINER_NAME="ebooks-$RANDOM_HEX"
message "One moment please, building Docker containing '$CONTAINER_NAME' using image '$DOCKER_IMAGE'..." "blue"
DOCKER_BUILD_CMD="docker build --no-cache -t $DOCKER_IMAGE"
if [[ "$DOCKER_FILE_PATH" != "" ]] && [[ "$DOCKER_FILE_PATH" != "$DEF_DOCKERFILE_PATH" ]]; then
    DOCKER_BUILD_CMD+=" -f $DOCKER_FILE_PATH"
fi
DOCKER_BUILD_CMD+=" ."
if [ $DEBUG = true ]; then
    eval $DOCKER_BUILD_CMD
else
    if [ $DEBUG = true ]; then
        message "Building Docker container with command: $DOCKER_BUILD_CMD" "blue"
    fi
    eval $DOCKER_BUILD_CMD >/dev/null 2>&1
fi
message "Docker container '$CONTAINER_NAME' built successfully." "green"

# ---------------------------------------------------------------------------------------------------------------------
# Build docker run command
# ---------------------------------------------------------------------------------------------------------------------
DOCKER_CMD="docker run -it"
if [ "$REMOVE_CONTAINER" = "true" ]; then
    DOCKER_CMD+=" --rm"
fi
DOCKER_CMD+=" --name $CONTAINER_NAME" # Add the container name
DOCKER_CMD+=" -v $INPUT_DIR:/$INPUT_MOUNT_POINT -v $OUTPUT_STAGING_DIR:/$OUTPUT_MOUNT_POINT "
if [ "$CORRUPT_MOUNT_POINT" != "" ]; then
    DOCKER_CMD+=" -v $CORRUPT_DIR:/$CORRUPT_MOUNT_POINT"
fi
if [ "$UNCERTAIN_MOUNT_POINT" != "" ]; then
    DOCKER_CMD+=" -v $UNCERTAIN_DIR:/$UNCERTAIN_MOUNT_POINT"
fi
if [ "$PAMPHLETS_MOUNT_POINT" != "" ]; then
    DOCKER_CMD+=" -v $PAMPHLETS_DIR:/$PAMPHLETS_MOUNT_POINT"
fi

# Add bindmounts to replace lib.sh and organize-ebooks.sh
DOCKER_CMD+=" -v $PROJECT_DIR/lib.sh:/ebook-tools/lib.sh"
DOCKER_CMD+=" -v $PROJECT_DIR/organize-ebooks.sh:/ebook-tools/organize-ebooks.sh"
DOCKER_CMD+=" ebooktools/scripts:latest"

# =====================================================================================================================
# SCRIPT OPTIONS for organize-ebooks.sh
# ---------------------------------------------------------------------------------------------------------------------
# Volume Options
# ---------------------------------------------------------------------------------------------------------------------
SCRIPT_OPTIONS=""
SCRIPT_OPTIONS+=" --output-folder=/$OUTPUT_MOUNT_POINT"
if [ "$CORRUPT_MOUNT_POINT" != "" ]; then
    SCRIPT_OPTIONS+=" --output-folder-corrupt=/$CORRUPT_MOUNT_POINT"
fi
if [ "$UNCERTAIN_MOUNT_POINT" != "" ]; then
    SCRIPT_OPTIONS+=" --output-folder-uncertain=/$UNCERTAIN_MOUNT_POINT"
fi
if [ "$PAMPHLETS_MOUNT_POINT" != "" ]; then
    SCRIPT_OPTIONS+=" --output-folder-pamphlets=/$PAMPHLETS_MOUNT_POINT"
fi
if [ "$FAILED_MOUNT_POINT" != "" ]; then
    SCRIPT_OPTIONS+=" --output-folder-failed=/$FAILED_MOUNT_POINT"
fi

# ---------------------------------------------------------------------------------------------------------------------
# General Options
# ---------------------------------------------------------------------------------------------------------------------
if [ "$VERBOSE" = "true" ]; then
    SCRIPT_OPTIONS+=" --verbose"
fi
if [ "$KEEP_METADATA" = "true" ]; then
    SCRIPT_OPTIONS+=" --keep-metadata"
fi
if [ "$CORRUPTION_CHECK_ONLY" = "true" ]; then
    SCRIPT_OPTIONS+=" --corruption-check-only"
fi
if [[ "$INPUT_EXTENSIONS" != "" ]] && [[ "$INPUT_EXTENSIONS" != "$DEF_INPUT_EXTENSIONS" ]]; then
    SCRIPT_OPTIONS+=" --tested-archive-extensions=\"$INPUT_EXTENSIONS\""
fi

# ---------------------------------------------------------------------------------------------------------------------
# ISBN Options
# ---------------------------------------------------------------------------------------------------------------------
if [[ $ORGANIZE_WITHOUT_ISBN = true ]]; then
    SCRIPT_OPTIONS+=" --organize-without-isbn"
fi
if [[ "$ISBN_METADATA_FETCH_ORDER" != "" ]] && [[ "$ISBN_METADATA_FETCH_ORDER" != "$DEF_ISBN_METADATA_FETCH_ORDER" ]]; then
    SCRIPT_OPTIONS+=" --metadata-fetch-order=\"$ISBN_METADATA_FETCH_ORDER\""
fi
if [[ "$WITHOUT_ISBN_SOURCES" != "" ]] && [[ "$WITHOUT_ISBN_SOURCES" != "$DEF_WITHOUT_ISBN_SOURCES" ]]; then
    SCRIPT_OPTIONS+=" --organize-without-isbn-sources=\"$WITHOUT_ISBN_SOURCES\""
fi
# if [[ "$REORDER_TEXT" != "" ]] && [[ "$REORDER_TEXT" != "$DEF_REORDER_TEXT" ]]; then
#     SCRIPT_OPTIONS+=" --reorder-files-for-grep=\"$REORDER_TEXT\""
# fi

# ---------------------------------------------------------------------------------------------------------------------
# OCR Options
# ---------------------------------------------------------------------------------------------------------------------
if [ "$OCR_ENABLED" = "true" ]; then
    SCRIPT_OPTIONS+=" --ocr-enabled=true"
    # if [ "$OCR_LANG" != "" ]; then
    #  SCRIPT_OPTIONS+=" --ocr-lang=$OCR_LANG"
    # fi
    if [ "$OCR_FIRST_LAST" != "" ]; then
        SCRIPT_OPTIONS+=" --ocr-only-first-last-pages=$OCR_FIRST_LAST"
    fi
else
    SCRIPT_OPTIONS+=" --ocr-enabled=false"
fi

if [[ "$OUTPUT_FORMAT" != "" ]] && [[ "$OUTPUT_FORMAT" != "$DEF_OUTPUT_FORMAT" ]]; then
    SCRIPT_OPTIONS+=" --output-filename-template=\"$OUTPUT_FORMAT\""
fi

SCRIPT_OPTIONS+=" /$INPUT_MOUNT_POINT"

# =====================================================================================================================
# RUN DOCKER CONTAINER
# ---------------------------------------------------------------------------------------------------------------------
FULL_CMD="${DOCKER_CMD} organize-ebooks.sh${SCRIPT_OPTIONS}"
DOCKER_OUTPUT_TMP=$(mktemp)
DOCKER_OUTPUT="$OUTPUT_DIR/last-run.log"
message "---------------------------------------------------------------------------------------------------------------------" "blue" true
message "Running Docker '$CONTAINER_NAME'"
message "   Configuration file:    $CONFIG_FILE"
message "   Input directory:       $INPUT_DIR"
message "   Output staging dir:    $OUTPUT_STAGING_DIR"
message "   Final renamed dir:     $INPUT_DIR"
message "   Docker output (tmp):   $DOCKER_OUTPUT_TMP"
message "   Docker output (final): $DOCKER_OUTPUT"
message ""
if [ $DEBUG = true ]; then
    message "Command:"
    message "$FULL_CMD"
fi
FULL_CMD+=" 2>&1 | tee $DOCKER_OUTPUT_TMP"
message "reset"

ran_docker=true
eval $FULL_CMD
mv -f "$DOCKER_OUTPUT_TMP" "$DOCKER_OUTPUT" >/dev/null 2>&1

# =====================================================================================================================
# PERFORM CLEANUP
# ---------------------------------------------------------------------------------------------------------------------
message "---------------------------------------------------------------------------------------------------------------------" "blue" true
message "Fixing filenames and directory structures..."
FIX_CMD="$FIX_SCRIPT $OUTPUT_STAGING_DIR"
eval "$FIX_CMD" >/dev/null 2>&1

message "---------------------------------------------------------------------------------------------------------------------" "blue" true
ORIGINALS_DIR="$INPUT_DIR/$ORIGINALS_SUBDIR"
mkdir -p "$ORIGINALS_DIR" >/dev/null 2>&1

mapfile -d '' -t STAGED_OUTPUT_FILES < <(find "$OUTPUT_STAGING_DIR" -maxdepth 1 -type f ! -name 'last-run.log' -print0)

if [ ${#STAGED_OUTPUT_FILES[@]} -gt 0 ]; then
    message "Archiving original files to $ORIGINALS_DIR..." "blue"
    ARCHIVED_INPUT_FILES=()
    for original_file in "${ORIGINAL_INPUT_FILES[@]}"; do
        if [ -f "$original_file" ]; then
            archived_path=$(get_unique_path "$ORIGINALS_DIR/$(basename "$original_file")")
            if cp -fp "$original_file" "$archived_path" >/dev/null 2>&1; then
                ARCHIVED_INPUT_FILES+=("$original_file")
            fi
        fi
    done

    message "Clearing original filenames from $INPUT_DIR..." "blue"
    for original_file in "${ARCHIVED_INPUT_FILES[@]}"; do
        rm -f "$original_file" >/dev/null 2>&1
    done

    message "Moving renamed files back into $INPUT_DIR..." "blue"
    for staged_file in "${STAGED_OUTPUT_FILES[@]}"; do
        final_path=$(get_unique_path "$INPUT_DIR/$(basename "$staged_file")")
        mv -f "$staged_file" "$final_path" >/dev/null 2>&1
    done
else
    message "No renamed files were produced in the staging directory." "yellow"
fi

rm -rf "$OUTPUT_STAGING_DIR" >/dev/null 2>&1
message "---------------------------------------------------------------------------------------------------------------------" "blue" false

cd "$RET_DIR" || exit >/dev/null 2>&1
message "All done." "green" false
message "reset"
