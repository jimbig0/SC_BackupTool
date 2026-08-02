#!/usr/bin/env bash
# Star Citizen User Profile Config Manager (Linux / LUG Launcher)
# Bash port of StarCitizen_UserConfig_Backup.bat
# https://github.com/jimbig0/SC_BackupTool
set -u
set -o pipefail

SC_BASE="${SC_BASE:-$HOME/Games/star-citizen/drive_c/Program Files/Roberts Space Industries/StarCitizen}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Documents/SC_Config_Backups}"

LIVE_BASE="$SC_BASE/LIVE"
PTU_BASE="$SC_BASE/PTU"
TECH_PREVIEW_BASE="$SC_BASE/TECH-PREVIEW"
LIVE_CONFIG="$LIVE_BASE/user/client/0"
PTU_CONFIG="$PTU_BASE/user/client/0"
TECH_PREVIEW_CONFIG="$TECH_PREVIEW_BASE/user/client/0"
MANIFEST_FILE="$LIVE_BASE/build_manifest.id"

BRANCH_VERSION=""
DATESTAMP=""
BACKUP_DIR=""
BACKUP_ZIP=""
RESTORE_PATH=""
LIVE_AVAILABLE=0
PTU_AVAILABLE=0
TECH_PREVIEW_AVAILABLE=0
LANG_PACK_ZIP=""
LANG_PACK_TEMP=""
LANG_PACK_ROOT=""
LANG_PACK_DATA=""

if find --help 2>&1 | grep -q -- '-printf'; then
    HAS_GNU_FIND=1
else
    HAS_GNU_FIND=0
fi

cleanup() {
    [[ -f "$LANG_PACK_ZIP" ]] && rm -f "$LANG_PACK_ZIP"
    [[ -d "$LANG_PACK_TEMP" ]] && rm -rf "$LANG_PACK_TEMP"
}
trap cleanup EXIT

check_dependencies() {
    local missing=0
    for cmd in zip unzip curl python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Missing required command: $cmd"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        echo "Please install missing dependencies, e.g. on CachyOS/Arch:"
        echo "  sudo pacman -S zip unzip curl python"
        echo "Note: the 'python' package provides the python3 command, and"
        echo "      'unzip' provides the zipinfo command used for zip checks."
        echo "Optional: 'jq' (used for GitHub API queries if installed)."
        exit 1
    fi
}

safe_zip_check() {
    local zipfile="$1"
    if [[ ! -f "$zipfile" ]]; then
        echo "Error: Zip file not found: \"$zipfile\""
        return 1
    fi
    if ! command -v zipinfo >/dev/null 2>&1; then
        echo "Error: zipinfo not available. Cannot verify zip contents safely."
        return 1
    fi
    local entry
    while IFS= read -r entry; do
        if [[ "$entry" = /* ]] || [[ "$entry" == *".."* ]]; then
            echo "Unsafe zip entry detected: $entry"
            return 1
        fi
    done < <(zipinfo -1 "$zipfile")
    return 0
}

initialize_date() {
    DATESTAMP="$(date +%Y_%m_%d)"
}

extract_branch_version() {
    BRANCH_VERSION="Unknown"
    if [[ -f "$MANIFEST_FILE" ]]; then
        if command -v jq >/dev/null 2>&1; then
            BRANCH_VERSION="$(jq -r '.Data.Branch // empty' "$MANIFEST_FILE" 2>/dev/null)"
        fi
        if [[ -z "$BRANCH_VERSION" ]]; then
            BRANCH_VERSION="$(sed -n 's/.*"Branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST_FILE" | head -n 1)"
            BRANCH_VERSION="${BRANCH_VERSION//$'\r'/}"
        fi
        BRANCH_VERSION="${BRANCH_VERSION//sc-alpha-/Alpha_}"
        BRANCH_VERSION="${BRANCH_VERSION%,}"
        BRANCH_VERSION="$(printf '%s' "$BRANCH_VERSION" | tr -c 'A-Za-z0-9._-' '_')"
        [[ -z "$BRANCH_VERSION" ]] && BRANCH_VERSION="Unknown"
    else
        echo "Warning: Manifest file not found. Using default version \"Unknown\""
    fi
}

create_backup_directory() {
    BACKUP_DIR="$BACKUP_ROOT/${DATESTAMP}_${BRANCH_VERSION}"
    mkdir -p "$BACKUP_DIR"
}

display_main_menu() {
    echo
    echo "========================================="
    echo "Star Citizen User Profile Config Manager"
    echo "========================================="
    echo "What would you like to do?"
    echo "1. Backup current LIVE configuration"
    echo "2. Restore configuration"
    echo "3. Create HOTFIX symbolic link to LIVE"
    echo "4. Download and install StarStrings language pack"
    echo "5. Exit"
    echo
}

main_menu() {
    while true; do
        display_main_menu
        read -r -p "Enter 1, 2, 3, 4, or 5: " choice || exit 0
        case "$choice" in
            1) perform_backup ;;
            2) perform_restore ;;
            3) create_hotfix_link ;;
            4) perform_language_pack_install ;;
            5) echo "Exiting Star Citizen User Profile Config Manager."; exit 0 ;;
            *) echo "Invalid choice. Please enter 1, 2, 3, 4, or 5." ;;
        esac
    done
}

perform_backup() {
    echo
    if [[ ! -d "$LIVE_CONFIG" ]]; then
        echo "Error: LIVE configuration path not found: \"$LIVE_CONFIG\""
        return
    fi
    echo "Backing up LIVE configuration to:"
    echo "  \"$BACKUP_DIR\""
    echo

    mkdir -p "$BACKUP_DIR"
    if ! cp -a "$LIVE_CONFIG"/. "$BACKUP_DIR"/; then
        echo "Warning: Copy encountered an error. Check paths above."
        return
    fi

    if ! compress_backup; then
        echo "Warning: Backup directory created but compression failed."
    else
        echo "Backup completed successfully."
        echo "Backup file: \"$BACKUP_ZIP\""
    fi
}

compress_backup() {
    BACKUP_ZIP="${BACKUP_DIR}.zip"
    [[ -f "$BACKUP_ZIP" ]] && rm -f "$BACKUP_ZIP"

    echo "Compressing backup to .zip file..."
    if ! ( cd "$BACKUP_DIR" && zip -r -q "$BACKUP_ZIP" . ); then
        echo "Error: Failed to create zip file."
        return 1
    fi

    if [[ -f "$BACKUP_ZIP" ]]; then
        echo "Removing temporary backup directory..."
        rm -rf "$BACKUP_DIR"
        echo "Compression completed successfully."
        echo "Backup file: \"$BACKUP_ZIP\""
    else
        echo "Error: Zip creation failed; backup directory preserved."
        return 1
    fi
    return 0
}

perform_restore() {
    echo
    find_available_backups
    [[ -n "$BACKUP_ZIP" ]] || return
    check_environment_availability || return
    display_restore_menu
    read -r -p "Enter your choice: " env_choice
    validate_and_set_restore_path
    [[ -n "$RESTORE_PATH" ]] || return
    create_restore_path || return
    confirm_and_execute_restore
}

find_available_backups() {
    BACKUP_ZIP=""
    if [[ ! -d "$BACKUP_ROOT" ]]; then
        echo "Error: Backup root directory not found: \"$BACKUP_ROOT\""
        echo "No backups available to restore."
        return
    fi

    local backups=()
    if [[ "$HAS_GNU_FIND" -eq 1 ]]; then
        while IFS= read -r -d '' f; do
            backups+=("${f#* }")
        done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\0' | sort -z -n -r)
    else
        while IFS= read -r -d '' f; do
            backups+=("$f")
        done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.zip' -print0)
    fi

    local count="${#backups[@]}"
    if [[ $count -eq 0 ]]; then
        echo "Error: No backup .zip files found in \"$BACKUP_ROOT\""
        return
    elif [[ $count -eq 1 ]]; then
        BACKUP_ZIP="${backups[0]}"
        echo "Found 1 backup: \"$BACKUP_ZIP\""
        echo
    else
        echo "Found $count available backups:"
        echo
        for (( i = 0; i < count; i++ )); do
            printf '%d. %s\n' "$((i + 1))" "$(basename "${backups[$i]}" .zip)"
        done
        echo
        read -r -p "Select backup by number: " backup_choice
        if [[ -z "$backup_choice" ]] || ! [[ "$backup_choice" =~ ^[0-9]+$ ]] || (( backup_choice < 1 || backup_choice > count )); then
            echo "Invalid selection. Exiting restore."
            BACKUP_ZIP=""
            read -r -p "Press Enter to continue..."
            return
        fi
        BACKUP_ZIP="${backups[$((backup_choice - 1))]}"
    fi

    if [[ ! -f "$BACKUP_ZIP" ]]; then
        echo "Error: Selected backup file not found: \"$BACKUP_ZIP\""
        BACKUP_ZIP=""
    fi
}

check_environment_availability() {
    LIVE_AVAILABLE=1
    [[ -d "$LIVE_BASE" ]] || LIVE_AVAILABLE=0
    PTU_AVAILABLE=0
    [[ -d "$PTU_BASE" ]] && PTU_AVAILABLE=1
    TECH_PREVIEW_AVAILABLE=0
    [[ -d "$TECH_PREVIEW_BASE" ]] && TECH_PREVIEW_AVAILABLE=1

    if [[ $LIVE_AVAILABLE -eq 0 && $PTU_AVAILABLE -eq 0 && $TECH_PREVIEW_AVAILABLE -eq 0 ]]; then
        echo "Error: No restore environments found."
        return 1
    fi
    return 0
}

display_restore_menu() {
    echo "Which environment do you want to restore to?"
    echo
    if [[ $LIVE_AVAILABLE -eq 1 ]]; then
        echo "1. LIVE"
    else
        echo "1. LIVE (not installed)"
    fi
    if [[ $PTU_AVAILABLE -eq 1 ]]; then
        echo "2. PTU"
    else
        echo "2. PTU (not installed)"
    fi
    if [[ $TECH_PREVIEW_AVAILABLE -eq 1 ]]; then
        echo "3. TECH-PREVIEW"
    else
        echo "3. TECH-PREVIEW (not installed)"
    fi
    echo
}

validate_and_set_restore_path() {
    RESTORE_PATH=""
    case "$env_choice" in
        1)
            if [[ $LIVE_AVAILABLE -eq 0 ]]; then
                echo "Error: LIVE environment is not installed. Cannot restore to unavailable environment."
                return
            fi
            RESTORE_PATH="$LIVE_CONFIG" ;;
        2)
            if [[ $PTU_AVAILABLE -eq 0 ]]; then
                echo "Error: PTU environment is not installed. Cannot restore to unavailable environment."
                return
            fi
            RESTORE_PATH="$PTU_CONFIG" ;;
        3)
            if [[ $TECH_PREVIEW_AVAILABLE -eq 0 ]]; then
                echo "Error: TECH-PREVIEW environment is not installed. Cannot restore to unavailable environment."
                return
            fi
            RESTORE_PATH="$TECH_PREVIEW_CONFIG" ;;
        *)
            echo "Invalid choice. Please enter 1, 2, or 3."
            return ;;
    esac
}

create_restore_path() {
    if [[ ! -d "$RESTORE_PATH" ]]; then
        echo
        echo "Creating restore path: \"$RESTORE_PATH\""
        mkdir -p "$RESTORE_PATH"
        if [[ ! -d "$RESTORE_PATH" ]]; then
            echo "Failed to create restore path. Aborting restore."
            exit 1
        fi
    else
        echo
        read -r -p "Restore path already exists. Overwrite existing files? [y/N] " overwrite
        case "$overwrite" in
            y|Y) ;;
            *) echo "Restore cancelled."; return 1 ;;
        esac
        echo "Clearing existing files in restore path..."
        find "$RESTORE_PATH" -mindepth 1 -delete
    fi
    return 0
}

confirm_and_execute_restore() {
    echo
    echo "You are about to restore configuration:"
    echo "From: \"$BACKUP_ZIP\""
    echo "To:   \"$RESTORE_PATH\""
    echo
    read -r -p "Are you sure you want to proceed? [y/N] " confirm
    case "$confirm" in
        y|Y) ;;
        *) echo "Restore cancelled."; return ;;
    esac

    echo
    echo "Restoring files..."
    if extract_backup; then
        echo "Restore completed successfully."
        read -r -p "Press Enter to continue..."
    else
        echo "Warning: Extraction encountered an error. Check paths above."
    fi
}

extract_backup() {
    echo "Extracting backup from: \"$BACKUP_ZIP\""
    if ! safe_zip_check "$BACKUP_ZIP"; then
        echo "Error: Refusing to extract unsafe backup archive."
        read -r -p "Press Enter to continue..."
        return 1
    fi
    if ! unzip -o -q "$BACKUP_ZIP" -d "$RESTORE_PATH"; then
        echo "Error: Failed to extract backup file."
        read -r -p "Press Enter to continue..."
        return 1
    fi
    return 0
}

create_hotfix_link() {
    echo
    echo "Creating HOTFIX symbolic link..."
    echo

    local hotfix="$SC_BASE/HOTFIX"

    if [[ -e "$hotfix" ]] || [[ -L "$hotfix" ]]; then
        if [[ -L "$hotfix" ]]; then
            echo "HOTFIX is a symbolic link."
            read -r -p "Remove existing HOTFIX symbolic link and create a new one? [y/N] " ans
            case "$ans" in
                y|Y) ;;
                *) echo "Operation cancelled."; read -r -p "Press Enter to continue..."; return ;;
            esac
            rm "$hotfix"
            if [[ -e "$hotfix" ]]; then
                echo "Error: Failed to remove existing HOTFIX symbolic link."
                read -r -p "Press Enter to continue..."
                return
            fi
        else
            echo "HOTFIX is a regular folder. Checking if it is empty..."
            if [[ -n "$(ls -A "$hotfix" 2>/dev/null)" ]]; then
                echo "Error: HOTFIX folder is not empty."
                echo "Please manually remove the HOTFIX folder or its contents."
                read -r -p "Press Enter to continue..."
                return
            fi
            read -r -p "Remove empty HOTFIX folder and create symbolic link? [y/N] " ans
            case "$ans" in
                y|Y) ;;
                *) echo "Operation cancelled."; read -r -p "Press Enter to continue..."; return ;;
            esac
            rmdir "$hotfix"
            if [[ -e "$hotfix" ]]; then
                echo "Error: Failed to remove empty HOTFIX folder."
                read -r -p "Press Enter to continue..."
                return
            fi
        fi
    else
        echo "HOTFIX folder does not exist. Ready to create symbolic link."
        echo
    fi

    if [[ ! -d "$LIVE_BASE" ]]; then
        echo "Error: LIVE folder not found at \"$LIVE_BASE\""
        echo "Cannot create symbolic link without LIVE folder."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo "This will create a symbolic link:"
    echo "  Link name: $hotfix"
    echo "  Target:   $LIVE_BASE"
    echo
    read -r -p "Do you want to proceed? [y/N] " ans
    case "$ans" in
        y|Y) ;;
        *) echo "Operation cancelled."; read -r -p "Press Enter to continue..."; return ;;
    esac

    echo
    echo "Creating symbolic link..."
    if ! ln -s "$LIVE_BASE" "$hotfix"; then
        echo "Error: Failed to create HOTFIX symbolic link."
        read -r -p "Press Enter to continue..."
        return
    fi
    echo
    echo "Successfully created HOTFIX symbolic link!"
    echo "HOTFIX now points to LIVE folder."
    read -r -p "Press Enter to continue..."
}

perform_language_pack_install() {
    echo
    if [[ ! -d "$LIVE_BASE" ]]; then
        echo "Error: LIVE folder not found at \"$LIVE_BASE\""
        echo "Cannot install language pack without LIVE folder."
        read -r -p "Press Enter to continue..."
        return
    fi
    download_language_pack || return
    extract_language_pack_zip || return
    install_language_pack_files
    cleanup_language_pack_temp
    read -r -p "Press Enter to continue..."
}

download_language_pack() {
    LANG_PACK_ZIP="${TMPDIR:-/tmp}/StarStrings_LanguagePack.zip"
    [[ -f "$LANG_PACK_ZIP" ]] && rm -f "$LANG_PACK_ZIP"

    echo "Getting latest StarStrings release URL from GitHub..."
    local url=""
    if command -v jq >/dev/null 2>&1; then
        url="$(curl -fsSL 'https://api.github.com/repos/MrKraken/StarStrings/releases/latest' \
            | jq -r '.assets[] | select(.name | test("\\.zip$")) | .browser_download_url' 2>/dev/null \
            | head -n 1)"
    else
        url="$(python3 - <<'PY' 2>/dev/null || true
import json, urllib.request
try:
    with urllib.request.urlopen('https://api.github.com/repos/MrKraken/StarStrings/releases/latest', timeout=30) as r:
        data = json.load(r)
except Exception:
    raise SystemExit(1)
for asset in data.get('assets', []):
    if asset.get('name', '').lower().endswith('.zip'):
        print(asset['browser_download_url'])
        break
PY
)"
    fi

    if [[ -z "$url" ]]; then
        echo "Error: Could not find a zip asset in latest release (API issue or rate-limited)."
        return 1
    fi

    echo "Downloading latest StarStrings language pack from GitHub..."
    if ! curl -fsSL -o "$LANG_PACK_ZIP" "$url"; then
        echo "Error: Failed to download language pack."
        return 1
    fi
    return 0
}

extract_language_pack_zip() {
    LANG_PACK_TEMP="${TMPDIR:-/tmp}/StarStrings_LanguagePack"
    rm -rf "$LANG_PACK_TEMP"
    mkdir -p "$LANG_PACK_TEMP"

    echo "Extracting language pack..."
    if ! safe_zip_check "$LANG_PACK_ZIP"; then
        echo "Error: Refusing to extract unsafe language pack archive."
        return 1
    fi
    if ! unzip -q "$LANG_PACK_ZIP" -d "$LANG_PACK_TEMP"; then
        echo "Error: Failed to extract language pack archive."
        return 1
    fi

    LANG_PACK_ROOT="$LANG_PACK_TEMP"
    if [[ ! -d "$LANG_PACK_ROOT/Data" ]] && [[ ! -d "$LANG_PACK_ROOT/data" ]]; then
        for d in "$LANG_PACK_TEMP"/*/; do
            if [[ -d "${d}Data" ]] || [[ -d "${d}data" ]]; then
                LANG_PACK_ROOT="${d%/}"
                break
            fi
        done
    fi

    LANG_PACK_DATA=""
    if [[ -d "$LANG_PACK_ROOT/Data" ]]; then
        LANG_PACK_DATA="$LANG_PACK_ROOT/Data"
    elif [[ -d "$LANG_PACK_ROOT/data" ]]; then
        LANG_PACK_DATA="$LANG_PACK_ROOT/data"
    fi

    if [[ -z "$LANG_PACK_DATA" ]]; then
        echo "Error: Extracted package does not contain a data folder."
        return 1
    fi
    return 0
}

install_language_pack_files() {
    if [[ ! -d "$LIVE_BASE" ]]; then
        echo "Error: LIVE folder not found at \"$LIVE_BASE\""
        return
    fi

    echo "Installing StarStrings language pack into LIVE root..."
    echo "Copying data folder to LIVE root..."
    mkdir -p "$LIVE_BASE/Data"
    if ! cp -a "$LANG_PACK_DATA/." "$LIVE_BASE/Data/"; then
        echo "Warning: Some data files may not have copied correctly."
    fi

    local live_cfg=""
    [[ -f "$LIVE_BASE/USER.cfg" ]] && live_cfg="$LIVE_BASE/USER.cfg"
    [[ -z "$live_cfg" && -f "$LIVE_BASE/user.cfg" ]] && live_cfg="$LIVE_BASE/user.cfg"

    local pack_cfg=""
    [[ -f "$LANG_PACK_ROOT/USER.cfg" ]] && pack_cfg="$LANG_PACK_ROOT/USER.cfg"
    [[ -z "$pack_cfg" && -f "$LANG_PACK_ROOT/user.cfg" ]] && pack_cfg="$LANG_PACK_ROOT/user.cfg"

    if [[ -n "$live_cfg" ]]; then
        update_usercfg_language "$live_cfg"
    elif [[ -n "$pack_cfg" ]]; then
        cp -a "$pack_cfg" "$LIVE_BASE/USER.cfg"
    else
        echo "Warning: user.cfg not found in extracted language pack."
    fi

    echo "Language pack installation completed."
}

update_usercfg_language() {
    local file="$1"
    if ! grep -qiE '^[[:space:]]*g_language[[:space:]]*=' "$file"; then
        echo 'g_language = english' >> "$file"
    fi
}

cleanup_language_pack_temp() {
    [[ -f "$LANG_PACK_ZIP" ]] && rm -f "$LANG_PACK_ZIP"
    [[ -d "$LANG_PACK_TEMP" ]] && rm -rf "$LANG_PACK_TEMP"
}

check_dependencies
initialize_date
extract_branch_version
create_backup_directory
main_menu
