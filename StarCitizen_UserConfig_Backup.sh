#!/usr/bin/env bash
# Star Citizen User Profile Config Manager (Linux / LUG Launcher)
# Bash port of StarCitizen_UserConfig_Backup.bat
# https://github.com/jimbig0/SC_BackupTool
#
# Overview:
#   This script manages Star Citizen under a Wine prefix (e.g. the LUG launcher):
#     - backs up / restores the LIVE user configuration to SC_Config_Backups
#     - creates a HOTFIX symbolic link that points to the LIVE folder
#     - installs the StarStrings language pack from GitHub
#     - maintains the per-build shader cache (safe cleanup + force delete)
#     - toggles Easy Anti-Cheat bypass for fast shader precompilation
#
# Debugging notes:
#   - Run with `bash -x` to trace every command.
#   - All paths can be overridden via environment variables (see below); the
#     script is portable to custom Wine prefixes / backup locations.
#   - On exit, a trap removes leftover temp files and empty backup folders.
set -u
set -o pipefail

# --- Configurable paths -----------------------------------------------------
# Each variable defaults to a sensible location but can be overridden:
#   SC_BASE        root Star Citizen install (contains LIVE/PTU/TECH-PREVIEW)
#   BACKUP_ROOT    where .zip backups are stored
#   LAUNCH_SCRIPT  the LUG sc-launch.sh edited by the Easy Anti-Cheat toggle
SC_BASE="${SC_BASE:-$HOME/Games/star-citizen/drive_c/Program Files/Roberts Space Industries/StarCitizen}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/Documents/SC_Config_Backups}"
LAUNCH_SCRIPT="${LAUNCH_SCRIPT:-$HOME/Games/star-citizen/sc-launch.sh}"

# --- Derived paths ----------------------------------------------------------
# SC_BASE is also the anchor for shader-cache auto-detection (see
# find_shader_cache_root), because it is where the Wine `drive_c` lives.
LIVE_BASE="$SC_BASE/LIVE"
PTU_BASE="$SC_BASE/PTU"
TECH_PREVIEW_BASE="$SC_BASE/TECH-PREVIEW"
# "user/client/0" is where Star Citizen keeps the per-install config files.
LIVE_CONFIG="$LIVE_BASE/user/client/0"
PTU_CONFIG="$PTU_BASE/user/client/0"
TECH_PREVIEW_CONFIG="$TECH_PREVIEW_BASE/user/client/0"
MANIFEST_FILE="$LIVE_BASE/build_manifest.id"

# --- Global state -----------------------------------------------------------
# Populated during startup / per-operation; declared here so `set -u` (no
# unbound-variable errors) does not complain when they are read before first use.
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
SHADER_CACHE_ROOT="${SHADER_CACHE_ROOT:-}"
INSTALLED_BUILD_VERSIONS=()

# Detect GNU find (Linux) vs BSD find (macOS). The backup list is sorted by
# mtime using GNU find's -printf; BSD find needs a fallback path (see
# find_available_backups).
if find --help 2>&1 | grep -q -- '-printf'; then
    HAS_GNU_FIND=1
else
    HAS_GNU_FIND=0
fi

# --- Exit-time cleanup ------------------------------------------------------
# cleanup_backup_root: removes any EMPTY subfolders of BACKUP_ROOT. Empty
# folders appear when the tool is opened (which pre-creates BACKUP_DIR) but
# no successful backup runs. rmdir only removes empty dirs, so folders that
# still contain files (e.g. from a failed compression) are left untouched.
cleanup_backup_root() {
    [[ -d "$BACKUP_ROOT" ]] || return 0
    local dir
    while IFS= read -r -d '' dir; do
        if rmdir "$dir" 2>/dev/null; then
            echo "Removed empty backup directory: \"$dir\""
        fi
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
}

# Registered via `trap ... EXIT` so it always runs, even on error exit paths.
cleanup() {
    [[ -f "$LANG_PACK_ZIP" ]] && rm -f "$LANG_PACK_ZIP"
    [[ -d "$LANG_PACK_TEMP" ]] && rm -rf "$LANG_PACK_TEMP"
    cleanup_backup_root
}
trap cleanup EXIT

check_dependencies() {
    # Fail early with a clear message if any required tool is missing,
    # rather than failing halfway through an operation.
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

# Zip-slip protection: rejects any archive entry that is an absolute path
# (/...) or contains "..". This prevents a malicious zip from extracting
# files outside the target directory during restore / language-pack install.
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

# Extract the human-readable branch name (e.g. "Alpha_4.9.0") from
# build_manifest.id. Prefers jq when available; falls back to sed parsing so
# jq is not strictly required. The "sc-alpha-X" prefix is rewritten to
# "Alpha_X" and any trailing comma / CR stripped for a clean folder name.
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

# Pre-create the timestamped backup folder at startup. Note: if the user never
# performs a successful backup, this folder stays empty and is cleaned up by
# cleanup_backup_root on exit.
create_backup_directory() {
    BACKUP_DIR="$BACKUP_ROOT/${DATESTAMP}_${BRANCH_VERSION}"
    mkdir -p "$BACKUP_DIR"
}

display_main_menu() {
    echo
    echo "=============================================================="
    echo "Star Citizen User Profile Config Manager"
    echo "=============================================================="
    echo "What would you like to do?"
    echo "1. Backup current LIVE configuration"
    echo "2. Restore configuration"
    echo "3. Create HOTFIX symbolic link to LIVE"
    echo "4. Download and install StarStrings language pack"
    echo "5. Troubleshooting (shader cache, Easy Anti-Cheat)"
    echo "6. Exit"
    echo
}

main_menu() {
    while true; do
        display_main_menu
        read -r -p "Enter 1, 2, 3, 4, 5, or 6: " choice || exit 0
        case "$choice" in
            1) perform_backup ;;
            2) perform_restore ;;
            3) create_hotfix_link ;;
            4) perform_language_pack_install ;;
            5) troubleshooting_menu ;;
            6) echo "Exiting Star Citizen User Profile Config Manager."; exit 0 ;;
            *) echo "Invalid choice. Please enter 1, 2, 3, 4, 5, or 6." ;;
        esac
    done
}

display_troubleshooting_menu() {
    echo
    echo "==============================================================="
    echo "Troubleshooting"
    echo "==============================================================="
    echo "1. Cleanup old shader cache folders"
    echo "2. Force delete shader cache (purge all shaders force rebuild)"
    echo "3. Toggle Easy Anti-Cheat (fast precompiling shader cache)"
    echo "4. Return to main menu"
    echo
}

troubleshooting_menu() {
    while true; do
        display_troubleshooting_menu
        read -r -p "Enter 1, 2, 3, or 4: " troubleshooting_choice || return
        case "$troubleshooting_choice" in
            1) cleanup_shader_cache ;;
            2) force_delete_shader_cache ;;
            3) toggle_eac ;;
            4) return ;;
            *) echo "Invalid choice. Please enter 1, 2, 3, or 4." ;;
        esac
    done
}

perform_backup() {
    # Flow: copy LIVE config into BACKUP_DIR, then compress that dir to
    # BACKUP_DIR.zip, then remove the uncompressed dir (see compress_backup).
    echo
    if [[ ! -d "$LIVE_CONFIG" ]]; then
        echo "Error: LIVE configuration path not found: \"$LIVE_CONFIG\""
        return
    fi
    echo "Backing up LIVE configuration to:"
    echo "  \"$BACKUP_DIR\""
    echo

    mkdir -p "$BACKUP_DIR"
    # Trailing "/." copies the *contents* of LIVE_CONFIG into BACKUP_DIR,
    # rather than nesting LIVE_CONFIG itself.
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
    # The zip lives alongside the dir it came from, e.g.
    #   SC_Config_Backups/2026_08_14_Alpha_4.9.0.zip
    # cd into BACKUP_DIR so the archive contains relative paths (no leading
    # absolute path components) and the internal layout matches the .bat tool.
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
    # Pipeline (each helper returns non-zero to abort early):
    #   find backups -> check environments -> pick target -> extract
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
    # With GNU find, sort zips by modification time (newest first) using
    # -printf '%T@ %p' plus the embedded timestamp as the sort key.
    if [[ "$HAS_GNU_FIND" -eq 1 ]]; then
        while IFS= read -r -d '' f; do
            backups+=("${f#* }")
        done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\0' | sort -z -n -r)
    else
        # BSD find fallback: no mtime sort, order is filesystem-dependent.
        while IFS= read -r -d '' f; do
            backups+=("$f")
        done < <(find "$BACKUP_ROOT" -maxdepth 1 -type f -name '*.zip' -print0)
    fi

    local count="${#backups[@]}"
    if [[ $count -eq 0 ]]; then
        echo "Error: No backup .zip files found in \"$BACKUP_ROOT\""
        return
    elif [[ $count -eq 1 ]]; then
        # Only one backup: use it without prompting.
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
    # Flags which of LIVE / PTU / TECH-PREVIEW are installed so the restore
    # menu only offers valid targets.
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
    # Map the user's menu choice (1/2/3) to the concrete config path, but
    # refuse if that environment is not actually installed.
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
    # Ensure the destination exists before extracting. If it already exists,
    # ask before overwriting and clear its contents for a clean restore.
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
        # -mindepth 1 keeps RESTORE_PATH itself (so the dir exists afterwards);
        # deletes everything inside of it.
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
    # Safety: refuse to extract if the archive contains path-traversal entries.
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
    # HOTFIX is a symlink pointing at the LIVE folder, letting the game
    # re-use the LIVE install. This routine clears any existing HOTFIX
    # (symlink or empty folder) before creating the new link.
    echo
    echo "Creating HOTFIX symbolic link..."
    echo

    local hotfix="$SC_BASE/HOTFIX"

    if [[ -e "$hotfix" ]] || [[ -L "$hotfix" ]]; then
        # Note: [[ -L ]] is checked first because a dangling symlink fails -e.
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
            # Regular folder: only removable if empty, otherwise the user
            # must clear it manually (safety: never delete user data).
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

toggle_eac() {
    # Toggles the EOS_USE_ANTICHEATCLIENTNULL env var in sc-launch.sh.
    # Bypassing EAC (setting the var) makes shaders compile much faster;
    # re-commenting the line re-enables EAC for online play.
    echo
    echo "========================================="
    echo "Easy Anti-Cheat Toggle (Fast shader cache)"
    echo "========================================="
    if [[ ! -f "$LAUNCH_SCRIPT" ]]; then
        echo "Error: sc-launch.sh not found at: \"$LAUNCH_SCRIPT\""
        echo "Override with the LAUNCH_SCRIPT environment variable if needed."
        read -r -p "Press Enter to continue..."
        return
    fi

    # Make sure the toggle lines exist in sc-launch.sh first.
    ensure_eac_lines

    # Active state = line is commented out; bypassed = line is uncommented.
    if grep -qE '^[[:space:]]*export[[:space:]]+EOS_USE_ANTICHEATCLIENTNULL=' "$LAUNCH_SCRIPT"; then
        echo "Easy Anti-Cheat is currently BYPASSED (shader cache mode)."
        echo "Make sure Star Citizen is CLOSED before changing this."
        echo
        read -r -p "Re-enable Easy Anti-Cheat now? [y/N] " ans
        case "$ans" in
            y|Y)
                sed -i 's/^[[:space:]]*export[[:space:]]\+EOS_USE_ANTICHEATCLIENTNULL=/# export EOS_USE_ANTICHEATCLIENTNULL=/' "$LAUNCH_SCRIPT"
                echo "Easy Anti-Cheat re-enabled (line commented back out)."
                ;;
            *) echo "No change made." ;;
        esac
    else
        echo "Easy Anti-Cheat is currently ACTIVE (normal mode)."
        echo "Bypassing EAC lets shaders compile much faster."
        echo "IMPORTANT: Re-run this option to re-enable EAC after shader caching has completed."
        echo "Do NOT try to connect to PU or Arena Commander untill EAC is re-enabled."
        echo
        read -r -p "Disable Easy Anti-Cheat for fast shader caching? [y/N] " ans
        case "$ans" in
            y|Y)
                sed -i 's/^[[:space:]]*#[[:space:]]*export[[:space:]]\+EOS_USE_ANTICHEATCLIENTNULL=/export EOS_USE_ANTICHEATCLIENTNULL=/' "$LAUNCH_SCRIPT"
                echo "Easy Anti-Cheat bypassed (line uncommented)."
                echo "After shader caching, close the game and re-enable EAC."
                ;;
            *) echo "No change made." ;;
        esac
    fi
    read -r -p "Press Enter to continue..."
}

ensure_eac_lines() {
    # Insert the EAC toggle lines into sc-launch.sh on first use, just before
    # the "# END ENVIRONMENT VARIABLES" marker, so subsequent toggles work.
    if grep -qF 'EOS_USE_ANTICHEATCLIENTNULL' "$LAUNCH_SCRIPT"; then
        return
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v head='##### Comment out line below to enable EasyAnticheat Enable it again to allow for fast compiling of shaders' \
        -v line='# export EOS_USE_ANTICHEATCLIENTNULL=1' '
        /^# END ENVIRONMENT VARIABLES/ && !inserted {
            print head
            print line
            print ""
            inserted=1
        }
        { print }
    ' "$LAUNCH_SCRIPT" > "$tmp"
    mv "$tmp" "$LAUNCH_SCRIPT"
    echo "Added Easy Anti-Cheat toggle lines to sc-launch.sh."
}

perform_language_pack_install() {
    # Pipeline: download -> extract -> copy data + manage USER.cfg -> cleanup.
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
    # Resolve the download URL of the latest release. Prefers jq; falls back
    # to an inline python3 script so either tool works.
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
    # Extract into a temp dir, then locate the root that actually contains
    # the Data folder (the zip may wrap everything in one top-level dir).
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
    # If Data/data is not at the top level, search for a wrapper directory.
    if [[ ! -d "$LANG_PACK_ROOT/Data" ]] && [[ ! -d "$LANG_PACK_ROOT/data" ]]; then
        for d in "$LANG_PACK_TEMP"/*/; do
            if [[ -d "${d}Data" ]] || [[ -d "${d}data" ]]; then
                LANG_PACK_ROOT="${d%/}"
                break
            fi
        done
    fi

    # Determine the case-insensitive Data folder path.
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

    # Ensure g_language is set. Prefer keeping the existing LIVE USER.cfg and
    # just appending the setting; only copy the pack's USER.cfg if none exists.
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

# Append g_language = english to a USER.cfg if that key isn't already present.
update_usercfg_language() {
    local file="$1"
    if ! grep -qiE '^[[:space:]]*g_language[[:space:]]*=' "$file"; then
        echo 'g_language = english' >> "$file"
    fi
}

cleanup_language_pack_temp() {
    # Remove downloaded zip + extracted temp dir (trap cleanup is the backup
    # safety net if this ever gets skipped on an error path).
    [[ -f "$LANG_PACK_ZIP" ]] && rm -f "$LANG_PACK_ZIP"
    [[ -d "$LANG_PACK_TEMP" ]] && rm -rf "$LANG_PACK_TEMP"
}

# --- Shader cache helpers ----------------------------------------------------
# Star Citizen stores a shader cache folder per build version under the local
# AppData folder. Folder names embed the build, e.g.
#   starcitizen_(sc-alpha-4.9.0)_rhzfp_0
# We parse that embedded version to decide whether a folder is still in use.

# Read the "sc-alpha-X.Y.Z" token out of a starcitizen_* folder name.
extract_manifest_branch() {
    local manifest="$1" branch=""
    [[ -f "$manifest" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        branch="$(jq -r '.Data.Branch // empty' "$manifest" 2>/dev/null)"
    fi
    if [[ -z "$branch" ]]; then
        branch="$(sed -n 's/.*"Branch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -n 1)"
    fi
    branch="${branch//$'\r'/}"
    [[ -n "$branch" ]] || return 1
    printf '%s' "$branch"
}

# Collect the branch of every installed environment (LIVE/PTU/TECH-PREVIEW).
gather_installed_branches() {
    INSTALLED_BUILD_VERSIONS=()
    local manifest branch
    for manifest in "$LIVE_BASE/build_manifest.id" "$PTU_BASE/build_manifest.id" "$TECH_PREVIEW_BASE/build_manifest.id"; do
        branch="$(extract_manifest_branch "$manifest")" || continue
        INSTALLED_BUILD_VERSIONS+=("$branch")
    done
}

# Locate the shader cache root. Uses SHADER_CACHE_ROOT if set, otherwise walks
# up from SC_BASE to find the Wine prefix (a directory containing drive_c),
# then looks for users/<user>/AppData/Local/star citizen.
find_shader_cache_root() {
    if [[ -n "$SHADER_CACHE_ROOT" ]] && [[ -d "$SHADER_CACHE_ROOT" ]]; then
        return 0
    fi
    local prefix="$SC_BASE"
    while [[ "$prefix" != "/" && -n "$prefix" ]]; do
        if [[ -d "$prefix/drive_c" ]]; then
            prefix="$prefix/drive_c"
            break
        fi
        prefix="$(dirname "$prefix")"
    done
    if [[ ! -d "$prefix/users" ]]; then
        return 1
    fi
    local user_dir candidate
    for user_dir in "$prefix"/users/*/; do
        [[ -d "$user_dir" ]] || continue
        for candidate in "$user_dir"AppData/Local/"star citizen" "$user_dir"AppData/Local/"Star Citizen"; do
            if [[ -d "$candidate" ]]; then
                SHADER_CACHE_ROOT="$candidate"
                return 0
            fi
        done
    done
    return 1
}

# Extract the build version embedded in a starcitizen_(sc-alpha-X.Y.Z)_... name.
shader_folder_version() {
    local folder="$1" name
    name="$(basename "$folder")"
    printf '%s' "$name" | sed -n 's/^starcitizen_(\(sc-alpha-[^)]*\))_.*/\1/p'
}

# Confirm a folder really is a shader cache before it is offered/deleted:
# name matches starcitizen_*, path is directly under SHADER_CACHE_ROOT, and it
# contains a recognized shader subfolder. This fails closed - never deletes
# anything that does not pass verification.
verify_shader_folder() {
    local folder="$1" name
    name="$(basename "$folder")"
    if [[ "$name" != starcitizen_* ]] || [[ "$folder" != "$SHADER_CACHE_ROOT"/* ]]; then
        return 1
    fi
    if [[ -d "$folder/shaders" ]] || [[ -d "$folder/vulkanshadercache" ]] || [[ -d "$folder/GraphicsSettings" ]]; then
        return 0
    fi
    return 1
}

force_delete_shader_cache() {
    # Purges shader cache folders regardless of installed build, forcing the
    # game to rebuild all shaders (useful for corruption / frame stutter).
    # Safe cleanup only targets folders for non-installed builds; this offers
    # EVERY verified folder.
    echo
    echo "========================================="
    echo "Force Delete Shader Cache"
    echo "========================================="
    echo

    if ! find_shader_cache_root; then
        echo "Error: Could not locate the Star Citizen shader cache directory."
        echo "Auto-detection failed. If using a custom Wine prefix, set SHADER_CACHE_ROOT."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo "Shader cache root: \"$SHADER_CACHE_ROOT\""
    echo
    echo "Scanning shader cache folders (only verified Star Citizen shader folders are offered)..."
    echo

    # 1) Collect all verified shader folders under the root.
    local candidates=() folder size last_mod
    while IFS= read -r -d '' folder; do
        if ! verify_shader_folder "$folder"; then
            echo "Skipping (not verified as a shader cache): $(basename "$folder")"
            continue
        fi
        local version
        version="$(shader_folder_version "$folder")"
        if [[ -z "$version" ]]; then
            echo "Skipping (unrecognised folder name): $(basename "$folder")"
            continue
        fi
        candidates+=("$folder")
    done < <(find "$SHADER_CACHE_ROOT" -maxdepth 1 -type d -name 'starcitizen_*' -print0 2>/dev/null | sort -z)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo
        echo "No verified shader cache folders found. Nothing to delete."
        read -r -p "Press Enter to continue..."
        return
    fi

    # 2) Show the candidates with size + last-modified for context.
    echo "The following shader cache folders were found:"
    local i=1
    for folder in "${candidates[@]}"; do
        size="$(du -sh "$folder" 2>/dev/null | cut -f1)"
        last_mod="$(stat -c '%y' "$folder" 2>/dev/null | cut -d. -f1)"
        printf '  %d. %s  (%s, last modified %s)\n' "$i" "$(basename "$folder")" "$size" "$last_mod"
        i=$((i + 1))
    done

    # 3) Ask which to delete: space-separated numbers, 'a' for all, or 0 to cancel.
    local count="${#candidates[@]}"
    local selection=""
    echo
    read -r -p "Enter folder number(s) to delete (space-separated), 'a' for all, or 0 to cancel: " selection
    if [[ -z "$selection" ]] || [[ "$selection" == "0" ]]; then
        echo "Force delete cancelled."
        read -r -p "Press Enter to continue..."
        return
    fi

    # 4) Resolve the selection into actual target paths (validated indices).
    local targets=() num
    if [[ "$selection" == "a" ]] || [[ "$selection" == "A" ]]; then
        targets=("${candidates[@]}")
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
                targets+=("${candidates[$((num - 1))]}")
            fi
        done
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "No valid selections. Force delete cancelled."
        read -r -p "Press Enter to continue..."
        return
    fi

    # 5) Final typed-YES confirmation before any deletion occurs.
    echo
    echo "You are about to permanently DELETE these shader cache folder(s):"
    for folder in "${targets[@]}"; do
        echo "  - $(basename "$folder") ($(du -sh "$folder" 2>/dev/null | cut -f1))"
    done
    echo
    read -r -p "Type YES to confirm, or anything else to cancel: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Force delete cancelled."
        read -r -p "Press Enter to continue..."
        return
    fi

    # 6) Delete, re-verifying each folder immediately before removal.
    for folder in "${targets[@]}"; do
        if ! verify_shader_folder "$folder"; then
            echo "Refusing to delete (verification failed): $(basename "$folder")"
            continue
        fi
        if rm -rf -- "$folder" 2>/dev/null; then
            echo "Deleted: $(basename "$folder")"
        else
            echo "Error deleting: $folder"
        fi
    done
    echo
    echo "Done. The game will rebuild shaders from scratch on next launch."
    read -r -p "Press Enter to continue..."
}

cleanup_shader_cache() {
    # Safe cleanup: only removes folders whose embedded build version is NOT
    # among the currently installed builds. Fails closed if no build version
    # can be determined (never guesses which folders to delete).
    echo
    echo "========================================="
    echo "Old Shader Cache Cleanup"
    echo "========================================="
    echo

    gather_installed_branches
    if [[ ${#INSTALLED_BUILD_VERSIONS[@]} -eq 0 ]]; then
        echo "Error: Could not determine any currently installed build version."
        echo "Refusing to remove shader cache folders without a known current build."
        read -r -p "Press Enter to continue..."
        return
    fi

    if ! find_shader_cache_root; then
        echo "Error: Could not locate the Star Citizen shader cache directory."
        echo "Auto-detection failed. If using a custom Wine prefix, set SHADER_CACHE_ROOT."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo "Shader cache root: \"$SHADER_CACHE_ROOT\""
    echo
    echo "Current installed build version(s):"
    local v
    for v in "${INSTALLED_BUILD_VERSIONS[@]}"; do
        echo "  - $v"
    done
    echo

    # 1) Classify each starcitizen_* folder: keep if its version matches an
    #    installed build, otherwise add to the candidate list.
    local candidates=() version size last_mod folder
    while IFS= read -r -d '' folder; do
        version="$(shader_folder_version "$folder")"
        if [[ -z "$version" ]]; then
            echo "Skipping (unrecognised folder name): $(basename "$folder")"
            continue
        fi
        if [[ " ${INSTALLED_BUILD_VERSIONS[*]} " == *" $version "* ]]; then
            echo "Keep (matches installed build): $(basename "$folder")"
        else
            candidates+=("$folder")
        fi
    done < <(find "$SHADER_CACHE_ROOT" -maxdepth 1 -type d -name 'starcitizen_*' -print0 2>/dev/null | sort -z)

    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo
        echo "No old shader cache folders found. Nothing to clean."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo
    echo "The following shader cache folder(s) are not used by any installed build:"
    local i=1
    for folder in "${candidates[@]}"; do
        size="$(du -sh "$folder" 2>/dev/null | cut -f1)"
        last_mod="$(stat -c '%y' "$folder" 2>/dev/null | cut -d. -f1)"
        printf '  %d. %s  (%s, last modified %s)\n' "$i" "$(basename "$folder")" "$size" "$last_mod"
        i=$((i + 1))
    done

    # 2) Same selection + YES-confirmation flow as force delete.
    local count="${#candidates[@]}"
    local selection=""
    echo
    read -r -p "Enter folder number(s) to delete (space-separated), 'a' for all, or 0 to cancel: " selection
    if [[ -z "$selection" ]] || [[ "$selection" == "0" ]]; then
        echo "Cleanup cancelled."
        read -r -p "Press Enter to continue..."
        return
    fi

    local targets=() num
    if [[ "$selection" == "a" ]] || [[ "$selection" == "A" ]]; then
        targets=("${candidates[@]}")
    else
        for num in $selection; do
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= count )); then
                targets+=("${candidates[$((num - 1))]}")
            fi
        done
    fi

    if [[ ${#targets[@]} -eq 0 ]]; then
        echo "No valid selections. Cleanup cancelled."
        read -r -p "Press Enter to continue..."
        return
    fi

    echo
    echo "You are about to permanently DELETE:"
    for folder in "${targets[@]}"; do
        echo "  - $(basename "$folder") ($(du -sh "$folder" 2>/dev/null | cut -f1))"
    done
    echo
    read -r -p "Type YES to confirm deletion, or anything else to cancel: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Cleanup cancelled."
        read -r -p "Press Enter to continue..."
        return
    fi

    # 3) Last-line-of-defense path check: basename + directory prefix must
    #    still match before rm -rf executes.
    for folder in "${targets[@]}"; do
        if [[ "$(basename "$folder")" != starcitizen_* ]] || [[ "$folder" != "$SHADER_CACHE_ROOT"/* ]]; then
            echo "Refusing to delete unexpected path: $folder"
            continue
        fi
        if rm -rf -- "$folder" 2>/dev/null; then
            echo "Deleted: $(basename "$folder")"
        else
            echo "Error deleting: $folder"
        fi
    done
    echo
    echo "Cleanup completed. Star Citizen will rebuild any shaders it still needs."
    read -r -p "Press Enter to continue..."
}

# --- Startup -----------------------------------------------------------------
# Verify tools are present, stamp date + branch, pre-create the backup folder
# (cleaned up on exit if unused), then enter the main menu loop.
check_dependencies
initialize_date
extract_branch_version
create_backup_directory
main_menu
