@echo off
:: Enable delayed expansion to allow variables to be updated and used within code blocks
setlocal EnableDelayedExpansion

:: Check for administrator privileges
:: This script requires admin rights to access Star Citizen installation
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo This script requires administrator privileges.
    pause
    exit /b
)

:: ============================================================================
:: INITIALIZATION
:: ============================================================================
call :InitializePaths
call :InitializeDate
call :ExtractBranchVersion
call :CreateBackupDirectory

:: ============================================================================
:: MAIN MENU AND OPERATION DISPATCH
:: ============================================================================
call :DisplayMainMenu
set /p choice=Enter 1 or 2: 

if "%choice%"=="1" (
    call :PerformBackup
) else if "%choice%"=="2" (
    call :PerformRestore
) else (
    echo Invalid choice. Exiting.
    exit /b
)

exit /b

:: ============================================================================
:: SUBROUTINES
:: ============================================================================

:: Initialize all paths for Star Citizen installation and configuration files
:: SC_BASE is the root installation directory
:: LIVE_BASE, PTU_BASE, and TECH_PREVIEW_BASE are the main branch directories
:: LIVE_CONFIG, PTU_CONFIG, and TECH_PREVIEW_CONFIG point to the user configuration subdirectories
:InitializePaths
set "SC_BASE=C:\Program Files\Roberts Space Industries\StarCitizen"
set "LIVE_BASE=%SC_BASE%\LIVE"
set "PTU_BASE=%SC_BASE%\PTU"
set "TECH_PREVIEW_BASE=%SC_BASE%\TECH-PREVIEW"
set "LIVE_CONFIG=%LIVE_BASE%\user\client\0"
set "PTU_CONFIG=%PTU_BASE%\user\client\0"
set "TECH_PREVIEW_CONFIG=!TECH_PREVIEW_BASE!\user\client\0"
set "MANIFEST_FILE=%LIVE_BASE%\build_manifest.id"
goto :eof

:: Extract current system date and break down into year, month, day components
:: The date is used to create timestamped backup directory names in YYYY_MM_DD format
:InitializeDate
for /f "tokens=2 delims==" %%I in ('"wmic os get LocalDateTime /value"') do set datetime=%%I
set "YYYY=!datetime:~0,4!"
set "MM=!datetime:~4,2!"
set "DD=!datetime:~6,2!"
set "DATESTAMP=!YYYY!_!MM!_!DD!"
goto :eof

:: Extract the Star Citizen branch version from the build manifest file
:: The version string is parsed from the manifest and will be used in the backup folder name
:: Defaults to "Unknown" if the manifest file doesn't exist
:: Cleans up the version string by removing quotes, spaces, and formatting
:: Converts "sc-alpha-X.X.X" format to "Alpha_X.X.X" for readability in folder names
:ExtractBranchVersion
set "BRANCH_VERSION=Unknown"
if exist "%MANIFEST_FILE%" (
    for /f "usebackq tokens=2 delims=:" %%A in (`findstr /i "\"Branch\"" "%MANIFEST_FILE%"`) do (
        set "BRANCH_VERSION=%%~A"
    )
) else (
    echo Warning: Manifest file not found. Using default version "Unknown"
)

:: Clean up version string
set "BRANCH_VERSION=!BRANCH_VERSION:"=!"
set "BRANCH_VERSION=!BRANCH_VERSION: =!"
set "BRANCH_VERSION=!BRANCH_VERSION:sc-alpha-=Alpha_!"
if "!BRANCH_VERSION:~-1!"=="," (
    set "BRANCH_VERSION=!BRANCH_VERSION:~0,-1!"
)
goto :eof

:: Create the backup root directory structure with timestamped and versioned subfolder
:: Backups are organized by date and version: SC_Config_Backups\YYYY_MM_DD_BranchVersion\
:: The /p flag creates all parent directories as needed
:CreateBackupDirectory
set "BACKUP_ROOT=%USERPROFILE%\Documents\SC_Config_Backups"
set "BACKUP_DIR=!BACKUP_ROOT!\!DATESTAMP!_!BRANCH_VERSION!"

if not exist "!BACKUP_DIR!" (
    mkdir "!BACKUP_DIR!" /p
)
goto :eof

:: Display the main menu prompt to the user with available operations
:DisplayMainMenu
echo.
echo =========================================
echo Star Citizen User Profile Config Manager
echo =========================================
echo What would you like to do?
echo 1. Backup current LIVE configuration
echo 2. Restore configuration
echo.
goto :eof

:: Perform the backup operation
:: Verifies the LIVE configuration directory exists before attempting backup
:: Creates a compressed .zip file containing all backup files
:: /E = Copy subdirectories including empty ones
:: /H = Copy hidden and system files
:: /C = Continue on errors
:: /I = Assume destination is a directory if it doesn't exist
:: /Y = Overwrite existing files without prompting
:PerformBackup
echo.
if not exist "%LIVE_CONFIG%" (
    echo Error: LIVE configuration path not found: "%LIVE_CONFIG%"
    exit /b
)
echo Backing up LIVE configuration to:
echo "!BACKUP_DIR!"
echo.

:: First, copy files to the temporary backup directory
xcopy "%LIVE_CONFIG%\*" "!BACKUP_DIR!\" /E /H /C /I /Y
if errorlevel 1 (
    echo Warning: xcopy encountered an error. Check paths above.
    exit /b
)

:: Create compressed zip file from the backup directory
call :CompressBackup
if errorlevel 1 (
    echo Warning: Backup directory created but compression failed.
) else (
    echo Backup completed successfully.
    echo Backup file: "!BACKUP_ZIP!"
)
goto :eof

:: Perform the restore operation
:: Verifies that backups exist before allowing restore
:: Checks which restore environments are available
:: Displays menu with only available options
:: Allows user to select from available backups
:: Validates user selection and creates restore paths as needed
:PerformRestore
echo.

call :FindAvailableBackups
if not defined BACKUP_ZIP (
    goto :eof
)

call :CheckEnvironmentAvailability
call :DisplayRestoreMenu
set /p envChoice=Enter your choice: 

call :ValidateAndSetRestorePath
if not defined RESTORE_PATH (
    goto :eof
)

call :CreateRestorePath
call :ConfirmAndExecuteRestore
goto :eof

:: Find available backups in the backup root directory
:: Searches for .zip backup files that have been compressed
:: If multiple backups exist, prompt user to select one
:: If only one backup exists, use that automatically
:FindAvailableBackups
set "BACKUP_ROOT=%USERPROFILE%\Documents\SC_Config_Backups"

if not exist "!BACKUP_ROOT!" (
    echo Error: Backup root directory not found: "!BACKUP_ROOT!"
    echo No backups available to restore.
    set "BACKUP_ZIP="
    goto :eof
)

:: Check if any backup zip files exist
set "BACKUP_COUNT=0"
for %%F in ("!BACKUP_ROOT!\*.zip") do (
    set /a BACKUP_COUNT+=1
)

if %BACKUP_COUNT% equ 0 (
    echo Error: No backup .zip files found in "!BACKUP_ROOT!"
    set "BACKUP_ZIP="
    goto :eof
) else if %BACKUP_COUNT% equ 1 (
    :: Only one backup exists, use it automatically
    for %%F in ("!BACKUP_ROOT!\*.zip") do (
        set "BACKUP_ZIP=%%F"
    )
    echo Found 1 backup: "!BACKUP_ZIP!"
    echo.
) else (
    :: Multiple backups exist, list them for user selection
    echo Found %BACKUP_COUNT% available backups:
    echo.
    set "BACKUP_INDEX=0"
    for %%F in ("!BACKUP_ROOT!\*.zip") do (
        set /a BACKUP_INDEX+=1
        set "BACKUP_!BACKUP_INDEX!=%%F"
        echo !BACKUP_INDEX!. %%~nF
    )
    echo.
    set /p BACKUP_CHOICE=Select backup by number: 
    
    :: Validate user selection
    if defined BACKUP_!BACKUP_CHOICE! (
        set "BACKUP_ZIP=!BACKUP_!BACKUP_CHOICE!!"
    ) else (
        echo Invalid selection. Exiting.
        set "BACKUP_ZIP="
        goto :eof
    )
)

:: Verify selected backup file exists and is readable
if not exist "!BACKUP_ZIP!" (
    echo Error: Selected backup file not found: "!BACKUP_ZIP!"
    set "BACKUP_ZIP="
    goto :eof
)
goto :eof

:: Compress the backup directory into a .zip file
:: Uses PowerShell to create the zip archive
:: The zip file is placed in the backup root directory with a .zip extension
:CompressBackup
set "BACKUP_ZIP=!BACKUP_DIR!.zip"

:: Check if zip file already exists and remove it
if exist "!BACKUP_ZIP!" (
    del "!BACKUP_ZIP!" /Q
)

:: Use PowerShell to compress the backup directory
echo Compressing backup to .zip file...
PowerShell -NoProfile -Command "Add-Type -AssemblyName 'System.IO.Compression.FileSystem'; [System.IO.Compression.ZipFile]::CreateFromDirectory(\"%BACKUP_DIR%\", \"%BACKUP_ZIP%\")"

if errorlevel 1 (
    echo Error: Failed to create zip file.
    goto :eof
)

:: Remove the uncompressed backup directory after successful compression
if exist "!BACKUP_ZIP!" (
    echo Removing temporary backup directory...
    rmdir "!BACKUP_DIR!" /S /Q
    echo Compression completed successfully.
    echo Backup file: "!BACKUP_ZIP!"
)
goto :eof
:CheckEnvironmentAvailability
set "LIVE_AVAILABLE=1"
if not exist "%LIVE_BASE%" (
    set "LIVE_AVAILABLE=0"
)

set "PTU_AVAILABLE=0"
if exist "%PTU_BASE%" (
    set "PTU_AVAILABLE=1"
)

set "TECH_PREVIEW_AVAILABLE=0"
if exist "%TECH_PREVIEW_BASE%" (
    set "TECH_PREVIEW_AVAILABLE=1"
)

:: Verify that at least one restore environment is available
if "!LIVE_AVAILABLE!"=="0" if "!PTU_AVAILABLE!"=="0" if "!TECH_PREVIEW_AVAILABLE!"=="0" (
    echo Error: No restore environments found.
    goto :eof
)
goto :eof
goto :eof

:: Display the restore menu with only available options
:DisplayRestoreMenu
echo Which environment do you want to restore to?
if "!LIVE_AVAILABLE!"=="1" (
    echo 1. LIVE
    set "MENU_CHOICE_1=LIVE"
)
if "!PTU_AVAILABLE!"=="1" (
    echo 2. PTU
    set "MENU_CHOICE_2=PTU"
)
if "!TECH_PREVIEW_AVAILABLE!"=="1" (
    echo 3. TECH-PREVIEW
    set "MENU_CHOICE_3=TECH-PREVIEW"
)
echo.
goto :eof

:: Validate user selection and set the restore path to the appropriate configuration directory
:ValidateAndSetRestorePath
if "%envChoice%"=="1" (
    if "!MENU_CHOICE_1!"=="" (
        echo Invalid choice. Exiting.
        goto :eof
    )
    set "RESTORE_PATH=!LIVE_CONFIG!"
) else if "%envChoice%"=="2" (
    if "!MENU_CHOICE_2!"=="" (
        echo Invalid choice. Exiting.
        goto :eof
    )
    set "RESTORE_PATH=!PTU_CONFIG!"
) else if "%envChoice%"=="3" (
    if "!MENU_CHOICE_3!"=="" (
        echo Invalid choice. Exiting.
        goto :eof
    )
    set "RESTORE_PATH=!TECH_PREVIEW_CONFIG!"
) else (
    echo Invalid choice. Exiting.
    goto :eof
)
goto :eof

:: Create the restore path and all subdirectories if they don't exist
:: This ensures the destination is ready before attempting to restore files
:CreateRestorePath
if not exist "!RESTORE_PATH!" (
    echo.
    echo Creating restore path: "!RESTORE_PATH!"
    mkdir "!RESTORE_PATH!"
    if not exist "!RESTORE_PATH!" (
        echo Failed to create restore path. Aborting restore.
        exit /b
    )
) else (
    :: If restore path already exists, prompt user to confirm overwrite
    echo.
    choice /c YN /m "Restore path already exists. Overwrite existing files?"
    if errorlevel 2 (
        echo Restore cancelled.
        goto :eof
    )
    :: Clear existing files to allow clean extraction
    echo Clearing existing files in restore path...
    del "!RESTORE_PATH!\*" /S /Q 2>nul
)
goto :eof

:: Display the restore operation summary and request user confirmation before proceeding
:ConfirmAndExecuteRestore
echo.
echo You are about to restore configuration:
echo From: "!BACKUP_ZIP!"
echo To:   "!RESTORE_PATH!"
echo.
choice /c YN /m "Are you sure you want to proceed?"
:: If user declines (errorlevel 2 = No), cancel the restore operation
if errorlevel 2 (
    echo Restore cancelled.
    goto :eof
)

:: Execute the restore operation by extracting the zip file to destination
echo.
echo Restoring files...
call :ExtractBackup

if errorlevel 1 (
    echo Warning: Extraction encountered an error. Check paths above.
) else (
    echo Restore completed successfully.
    pause
)
goto :eof

:: Extract the compressed backup zip file to the restore destination
:: Uses PowerShell to extract the zip archive
:: Files in the destination directory will be overwritten if they already exist
:: Paths with spaces and special characters are properly escaped
:ExtractBackup
echo Extracting backup from: "!BACKUP_ZIP!"
PowerShell -NoProfile -Command "Add-Type -AssemblyName 'System.IO.Compression.FileSystem'; [System.IO.Compression.ZipFile]::ExtractToDirectory(\"%BACKUP_ZIP%\", \"%RESTORE_PATH%\")"

if errorlevel 1 (
    echo Error: Failed to extract backup file.
    pause
    goto :eof
)

goto :eof
