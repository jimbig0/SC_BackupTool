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
:MainMenuLoop
call :DisplayMainMenu
set /p choice=Enter 1, 2, 3, 4, 5, or 6: 

if "%choice%"=="1" (
    call :PerformBackup
    goto :MainMenuLoop
) else if "%choice%"=="2" (
    call :PerformRestore
    goto :MainMenuLoop
) else if "%choice%"=="3" (
    call :CreateHOTFIXLink
    goto :MainMenuLoop
) else if "%choice%"=="4" (
    call :PerformLanguagePackInstall
    goto :MainMenuLoop
) else if "%choice%"=="5" (
    call :TroubleshootingMenu
    goto :MainMenuLoop
) else if "%choice%"=="6" (
    echo Exiting Star Citizen User Profile Config Manager.
    call :CleanupBackupRoot
    exit /b
) else (
    echo Invalid choice. Please enter 1, 2, 3, 4, 5, or 6.
    goto :MainMenuLoop
)

exit /b

:: ============================================================================
:: TROUBLESHOOTING SUBMENU
:: ============================================================================
:: Loops until the user picks "Return to main menu" (%ts_choice%==3).
:: All submenu routines are invoked with `call` so control comes back here.
:TroubleshootingMenu
call :DisplayTroubleshootingMenu
set /p ts_choice=Enter 1, 2, or 3: 

if "%ts_choice%"=="1" (
    call :CleanupShaderCache
    goto :TroubleshootingMenu
) else if "%ts_choice%"=="2" (
    call :ForceDeleteShaderCache
    goto :TroubleshootingMenu
) else if "%ts_choice%"=="3" (
    goto :eof
) else (
    echo Invalid choice. Please enter 1, 2, or 3.
    goto :TroubleshootingMenu
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
set "SHADER_CACHE_ROOT=%LOCALAPPDATA%\Star Citizen"
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
    mkdir "!BACKUP_DIR!"
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
echo 3. Create HOTFIX symbolic link to LIVE
echo 4. Download and install StarStrings language pack
echo 5. Troubleshooting (shader cache)
echo 6. Exit
echo.
goto :eof

:: Display the troubleshooting submenu
:DisplayTroubleshootingMenu
echo.
echo =========================================
echo Troubleshooting
echo =========================================
echo 1. Cleanup old shader cache folders
echo 2. Force delete shader cache (verified, forces rebuild)
echo 3. Return to main menu
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
    
    :: Validate user selection is a number within range
    if "!BACKUP_CHOICE!"=="" (
        echo Invalid selection. Exiting restore.
        set "BACKUP_ZIP="
        pause
        goto :eof
    )
    
    :: Use call to expand the dynamic variable name
    for /L %%I in (1,1,!BACKUP_INDEX!) do (
        if "!BACKUP_CHOICE!"=="%%I" (
            set "BACKUP_ZIP=!BACKUP_%%I!"
        )
    )
    
    if not defined BACKUP_ZIP (
        echo Invalid selection. Please enter a number between 1 and !BACKUP_INDEX!.
        set "BACKUP_ZIP="
        pause
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

:: Display the restore menu with fixed options for all three environments
:DisplayRestoreMenu
echo Which environment do you want to restore to?
echo.
if "!LIVE_AVAILABLE!"=="1" (
    echo 1. LIVE
) else (
    echo 1. LIVE (not installed)
)
if "!PTU_AVAILABLE!"=="1" (
    echo 2. PTU
) else (
    echo 2. PTU (not installed)
)
if "!TECH_PREVIEW_AVAILABLE!"=="1" (
    echo 3. TECH-PREVIEW
) else (
    echo 3. TECH-PREVIEW (not installed)
)
echo.
goto :eof

:: Validate user selection and set the restore path to the appropriate configuration directory
:ValidateAndSetRestorePath
if "%envChoice%"=="1" (
    if "!LIVE_AVAILABLE!"=="0" (
        echo Error: LIVE environment is not installed. Cannot restore to unavailable environment.
        set "RESTORE_PATH="
        goto :eof
    )
    set "RESTORE_PATH=!LIVE_CONFIG!"
) else if "%envChoice%"=="2" (
    if "!PTU_AVAILABLE!"=="0" (
        echo Error: PTU environment is not installed. Cannot restore to unavailable environment.
        set "RESTORE_PATH="
        goto :eof
    )
    set "RESTORE_PATH=!PTU_CONFIG!"
) else if "%envChoice%"=="3" (
    if "!TECH_PREVIEW_AVAILABLE!"=="0" (
        echo Error: TECH-PREVIEW environment is not installed. Cannot restore to unavailable environment.
        set "RESTORE_PATH="
        goto :eof
    )
    set "RESTORE_PATH=!TECH_PREVIEW_CONFIG!"
) else (
    echo Invalid choice. Please enter 1, 2, or 3.
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

:: Create a symbolic link from HOTFIX to LIVE folder
:: Validates that HOTFIX doesn't already exist or is empty
:: Creates the link in the Star Citizen installation directory
:: Requires administrator privileges which are already verified at startup
:CreateHOTFIXLink
echo.
echo Creating HOTFIX symbolic link...
echo.

:: Check if HOTFIX already exists
if exist "%SC_BASE%\HOTFIX" (
    echo HOTFIX folder detected. Checking if it is a symbolic link or directory...
    
    :: Try to remove it if it's a symbolic link
    fsutil reparsepoint query "%SC_BASE%\HOTFIX" >nul 2>&1
    if errorlevel 0 (
        :: It's a symbolic link, check if we can safely remove it
        echo HOTFIX is a symbolic link.
        choice /c YN /m "Remove existing HOTFIX symbolic link and create a new one?"
        if errorlevel 2 (
            echo Operation cancelled.
            pause
            goto :eof
        )
        
        :: Remove the existing symbolic link
        rmdir "%SC_BASE%\HOTFIX" /S /Q
        if errorlevel 1 (
            echo Error: Failed to remove existing HOTFIX symbolic link.
            pause
            goto :eof
        )
    ) else (
        :: It's a regular folder, check if empty
        echo HOTFIX is a regular folder. Checking if it is empty...
        
        for /d %%F in ("%SC_BASE%\HOTFIX\*") do (
            echo Error: HOTFIX folder is not empty. Contains subdirectories.
            echo Please manually remove the HOTFIX folder or its contents.
            pause
            goto :eof
        )
        
        for %%F in ("%SC_BASE%\HOTFIX\*") do (
            echo Error: HOTFIX folder is not empty. Contains files.
            echo Please manually remove the HOTFIX folder or its contents.
            pause
            goto :eof
        )
        
        :: Folder is empty, ask permission to remove it
        choice /c YN /m "Remove empty HOTFIX folder and create symbolic link?"
        if errorlevel 2 (
            echo Operation cancelled.
            pause
            goto :eof
        )
        
        rmdir "%SC_BASE%\HOTFIX" /Q
        if errorlevel 1 (
            echo Error: Failed to remove empty HOTFIX folder.
            pause
            goto :eof
        )
    )
) else (
    echo HOTFIX folder does not exist. Ready to create symbolic link.
    echo.
)

:: Verify LIVE folder exists before creating the link
if not exist "%LIVE_BASE%" (
    echo Error: LIVE folder not found at "%LIVE_BASE%"
    echo Cannot create symbolic link without LIVE folder.
    pause
    goto :eof
)

:: Display confirmation before creating the link
echo This will create a symbolic link:
echo   Link name: %SC_BASE%\HOTFIX
echo   Target:   %SC_BASE%\LIVE
echo.
choice /c YN /m "Do you want to proceed?"
if errorlevel 2 (
    echo Operation cancelled.
    pause
    goto :eof
)

:: Change to SC_BASE directory and create the symbolic link
echo.
echo Creating symbolic link...
cd /d "%SC_BASE%"
mklink /D HOTFIX LIVE

if errorlevel 1 (
    echo Error: Failed to create HOTFIX symbolic link.
    echo Make sure you are running as administrator.
    pause
    goto :eof
) else (
    echo.
    echo Successfully created HOTFIX symbolic link!
    echo HOTFIX now points to LIVE folder.
    pause
    goto :eof
)

:: Download and install the StarStrings language pack from the latest GitHub release
:PerformLanguagePackInstall
echo.
if not exist "%LIVE_BASE%" (
    echo Error: LIVE folder not found at "%LIVE_BASE%"
    echo Cannot install language pack without LIVE folder.
    pause
    goto :eof
)

call :DownloadLanguagePack
if errorlevel 1 goto :eof

call :ExtractLanguagePackZip
if errorlevel 1 goto :eof

call :InstallLanguagePackFiles
call :CleanupLanguagePackTemp
pause
goto :eof

:DownloadLanguagePack
set "LANG_PACK_ZIP=%TEMP%\StarStrings_LanguagePack.zip"
if exist "!LANG_PACK_ZIP!" del /Q "!LANG_PACK_ZIP!"

echo Downloading latest StarStrings language pack from GitHub...
PowerShell -NoProfile -Command "$release=Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/MrKraken/StarStrings/releases/latest'; $asset=$release.assets | Where-Object { $_.name -match '\.zip$' } | Select-Object -First 1; if($null -eq $asset){Write-Error 'No zip asset found'; exit 1}; Invoke-WebRequest -Uri $asset.browser_download_url -OutFile '%TEMP%\\StarStrings_LanguagePack.zip' -UseBasicParsing"

if errorlevel 1 (
    echo Error: Failed to download language pack.
    goto :eof
)

goto :eof

:ExtractLanguagePackZip
set "LANG_PACK_TEMP=%TEMP%\StarStrings_LanguagePack"
if exist "!LANG_PACK_TEMP!" rmdir /S /Q "!LANG_PACK_TEMP!"
mkdir "!LANG_PACK_TEMP!"

echo Extracting language pack...
PowerShell -NoProfile -Command "Add-Type -AssemblyName 'System.IO.Compression.FileSystem'; [System.IO.Compression.ZipFile]::ExtractToDirectory('%TEMP%\\StarStrings_LanguagePack.zip','%TEMP%\\StarStrings_LanguagePack')"

if errorlevel 1 (
    echo Error: Failed to extract language pack archive.
    goto :eof
)

set "LANG_PACK_ROOT=!LANG_PACK_TEMP!"
if not exist "!LANG_PACK_ROOT!\data" (
    for /d %%D in ("!LANG_PACK_TEMP!\*") do (
        if exist "%%~fD\data" set "LANG_PACK_ROOT=%%~fD"
    )
)

if not exist "!LANG_PACK_ROOT!\data" (
    echo Error: Extracted package does not contain a data folder.
    goto :eof
)

goto :eof

:InstallLanguagePackFiles
if not exist "%LIVE_BASE%" (
    echo Error: LIVE folder not found at "%LIVE_BASE%"
    goto :eof
)

echo Installing StarStrings language pack into LIVE root...

echo Copying data folder to LIVE root...
xcopy "!LANG_PACK_ROOT!\data\*" "%LIVE_BASE%\data\" /E /H /C /I /Y >nul
if errorlevel 1 (
    echo Warning: Some data files may not have copied correctly.
)

if exist "%LIVE_BASE%\user.cfg" (
    call :UpdateUserCfgLanguageLine "%LIVE_BASE%\user.cfg"
) else if exist "!LANG_PACK_ROOT!\user.cfg" (
    copy /Y "!LANG_PACK_ROOT!\user.cfg" "%LIVE_BASE%\user.cfg" >nul
) else (
    echo Warning: user.cfg not found in extracted language pack.
)

echo Language pack installation completed.
goto :eof

:UpdateUserCfgLanguageLine
PowerShell -NoProfile -Command "$file = Get-Item -LiteralPath '%~1'; $lines = Get-Content -LiteralPath $file; if(-not ($lines -match '^[\s]*g_language[\s]*=')) { Add-Content -LiteralPath $file -Value 'g_language = english' }"
if errorlevel 1 (
    echo Warning: Failed to update existing user.cfg with language setting.
)
goto :eof

:CleanupLanguagePackTemp
if exist "!LANG_PACK_ZIP!" del /Q "!LANG_PACK_ZIP!"
if exist "!LANG_PACK_TEMP!" rmdir /S /Q "!LANG_PACK_TEMP!"
goto :eof

:: Perform old shader cache cleanup by comparing installed build versions in
:: build_manifest.id against the version embedded in each starcitizen_* folder.
:: Folder names look like starcitizen_(sc-alpha-4.9.0)_rhzfp_0 - the version
:: is the token between the parentheses.
:CleanupShaderCache
echo.
echo =========================================
echo Old Shader Cache Cleanup
echo =========================================
echo.

call :GatherInstalledBuildVersions
if "!INSTALLED_BUILD_VERSIONS!"=="" (
    echo Error: Could not determine any currently installed build version.
    echo Refusing to remove shader cache folders without a known current build.
    pause
    goto :eof
)

if not exist "!SHADER_CACHE_ROOT!" (
    echo Error: Shader cache folder not found: "!SHADER_CACHE_ROOT!"
    pause
    goto :eof
)

echo Shader cache root: "!SHADER_CACHE_ROOT!"
echo.
echo Current installed build version^(s^):
for %%V in (!INSTALLED_BUILD_VERSIONS!) do echo   - %%V
echo.

:: Enumerate shader cache folders and classify them against installed builds.
:: NOTE: delayed expansion (!var!) is required here because the variables
:: (FOLDER_NAME, FOLDER_VERSION, IS_MATCH, CANDIDATE_*) are set and read
:: inside the same parenthesized FOR block. %var% would be expanded once at
:: parse time and read stale values.
set "CANDIDATE_COUNT=0"
set "CANDIDATE_LIST="
for /d %%D in ("!SHADER_CACHE_ROOT!\starcitizen_*") do (
    set "FOLDER_NAME=%%~nxD"
    set "FOLDER_VERSION="
    :: Pull the build version out of the folder name (token 2 between parens).
    for /f "tokens=2 delims=()" %%V in ("!FOLDER_NAME!") do set "FOLDER_VERSION=%%V"
    if not defined FOLDER_VERSION (
        echo Skipping ^(unrecognised folder name^): !FOLDER_NAME!
    ) else (
        set "IS_MATCH=0"
        for %%V in (!INSTALLED_BUILD_VERSIONS!) do (
            if "%%V"=="!FOLDER_VERSION!" set "IS_MATCH=1"
        )
        if "!IS_MATCH!"=="1" (
            echo Keep ^(matches installed build^): !FOLDER_NAME!
        ) else (
            :: Registered as a candidate for deletion. CANDIDATE_<n> holds the
            :: full path, CANDIDATE_NAME_<n> the folder name, so paths with odd
            :: characters survive. CANDIDATE_LIST tracks the indices.
            set /a CANDIDATE_COUNT+=1
            set "CANDIDATE_!CANDIDATE_COUNT!=%%~fD"
            set "CANDIDATE_NAME_!CANDIDATE_COUNT!=!FOLDER_NAME!"
            set "CANDIDATE_LIST=!CANDIDATE_LIST! !CANDIDATE_COUNT!"
            echo Old ^(not used by any installed build^): !FOLDER_NAME!
        )
    )
)

if %CANDIDATE_COUNT% equ 0 (
    echo.
    echo No old shader cache folders found. Nothing to clean.
    pause
    goto :eof
)

echo.
echo The following shader cache folder^(s^) are not used by any installed build:
for %%D in (!CANDIDATE_LIST!) do (
    call :GetFolderSizeMB "!CANDIDATE_%%D!" FSIZE
    echo   %%D. !CANDIDATE_NAME_%%D!  ^(!FSIZE! MB^)
)
echo.

set /p SELECTION=Enter folder number^(s^) to delete ^(space-separated^), 'a' for all, or 0 to cancel: 
if "%SELECTION%"=="0" (
    echo Cleanup cancelled.
    pause
    goto :eof
)
if "%SELECTION%"=="" (
    echo No selection made. Cleanup cancelled.
    pause
    goto :eof
)

:: Resolve the selection into a deletion list
set "DELETE_LIST="
if /i "%SELECTION%"=="a" (
    set "DELETE_LIST=!CANDIDATE_LIST!"
) else (
    for %%N in (!CANDIDATE_LIST!) do (
        for %%S in (%SELECTION%) do (
            if "%%S"=="%%N" set "DELETE_LIST=!DELETE_LIST! %%N"
        )
    )
)

if "!DELETE_LIST!"=="" (
    echo No valid selections. Cleanup cancelled.
    pause
    goto :eof
)

echo.
echo You are about to permanently DELETE:
for %%D in (!DELETE_LIST!) do (
    echo   - !CANDIDATE_NAME_%%D!
)
echo.
set /p CONFIRM=Type YES to confirm deletion, or anything else to cancel: 
if /i not "!CONFIRM!"=="YES" (
    echo Cleanup cancelled.
    pause
    goto :eof
)

for %%D in (!DELETE_LIST!) do (
    if exist "!CANDIDATE_%%D!" (
        rmdir /S /Q "!CANDIDATE_%%D!"
        if exist "!CANDIDATE_%%D!" (
            echo Error deleting: !CANDIDATE_NAME_%%D!
        ) else (
            echo Deleted: !CANDIDATE_NAME_%%D!
        )
    )
)
echo.
echo Cleanup completed. Star Citizen will rebuild any shaders it still needs.
pause
goto :eof

:: Read the branch name from a given build_manifest.id into INSTALLED_BUILD_VERSIONS
:: Evaluates LIVE, PTU, and TECH-PREVIEW manifests for a complete picture.
:: Multiple branches are comma-joined so the FOR over INSTALLED_BUILD_VERSIONS
:: later iterates each one. MANIFEST_BRANCH is a subroutine-output variable:
:: it is set by ExtractManifestBranch and consumed here.
:GatherInstalledBuildVersions
set "INSTALLED_BUILD_VERSIONS="
set "MANIFEST_BRANCH="
call :ExtractManifestBranch "%LIVE_BASE%\build_manifest.id"
if defined MANIFEST_BRANCH set "INSTALLED_BUILD_VERSIONS=!MANIFEST_BRANCH!"
call :ExtractManifestBranch "%PTU_BASE%\build_manifest.id"
if defined MANIFEST_BRANCH if "!INSTALLED_BUILD_VERSIONS!"=="" (set "INSTALLED_BUILD_VERSIONS=!MANIFEST_BRANCH!") else (set "INSTALLED_BUILD_VERSIONS=!INSTALLED_BUILD_VERSIONS!,!MANIFEST_BRANCH!")
call :ExtractManifestBranch "%TECH_PREVIEW_BASE%\build_manifest.id"
if defined MANIFEST_BRANCH if "!INSTALLED_BUILD_VERSIONS!"=="" (set "INSTALLED_BUILD_VERSIONS=!MANIFEST_BRANCH!") else (set "INSTALLED_BUILD_VERSIONS=!INSTALLED_BUILD_VERSIONS!,!MANIFEST_BRANCH!")
goto :eof

:: Parse the Branch value from a build_manifest.id JSON file into MANIFEST_BRANCH
:: Uses findstr to grab the line, then tokens=2 delims=: gets the value side.
:: Quotes, spaces and trailing commas are stripped afterwards.
:ExtractManifestBranch
set "MANIFEST_BRANCH="
if not exist "%~1" goto :eof
for /f "usebackq tokens=2 delims=:" %%A in (`findstr /i "Branch" "%~1"`) do (
    set "MANIFEST_BRANCH=%%~A"
)
set "MANIFEST_BRANCH=!MANIFEST_BRANCH:"=!"
set "MANIFEST_BRANCH=!MANIFEST_BRANCH: =!"
set "MANIFEST_BRANCH=!MANIFEST_BRANCH:,=!"
goto :eof

:: Calculate a folder's size in MB using PowerShell, stores result in variable %2
:GetFolderSizeMB
set "%~2=0"
for /f "usebackq delims=" %%S in (`powershell -NoProfile -Command "$p=Get-Item -LiteralPath '%~1'; $sum=(Get-ChildItem -LiteralPath $p.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum; if($sum){[math]::Round($sum/1MB,1)}else{0}"`) do set "%~2=%%S"
goto :eof

:: Remove any empty subdirectories from the backup root so that only zip
:: archives remain. Runs when the utility exits.
:CleanupBackupRoot
if not exist "!BACKUP_ROOT!" goto :eof
for /d %%D in ("!BACKUP_ROOT!\*") do (
    rmdir "%%~fD" 2>nul
    if not exist "%%~fD" (
        echo Removed empty backup directory: "%%~fD"
    )
)
goto :eof

:: Verify that a folder is genuinely a Star Citizen shader cache: it must live
:: directly under SHADER_CACHE_ROOT, be named starcitizen_*, and contain
:: recognizable shader subfolders.
:: Returns via ERRORLEVEL (exit /b 0 = valid, exit /b 1 = invalid). Callers
:: must check it with `if errorlevel 1` AFTER `call`, since the intermediate
:: `if exist` lines do not alter ERRORLEVEL into a reliable TRUE/FALSE signal.
:VerifyShaderFolder
set "VF_FOLDER="
set "VF_NAME="
set "VF_VERSION="
set "VF_VERIFIED=0"
set "VF_FOLDER=%~1"
if not defined VF_FOLDER exit /b 1
set "VF_NAME=%~nx1"
:: Version token between the parentheses, e.g. sc-alpha-4.9.0 from
:: starcitizen_(sc-alpha-4.9.0)_rhzfp_0. Must exist to pass.
for /f "tokens=2 delims=()" %%V in ("!VF_NAME!") do set "VF_VERSION=%%V"
if not defined VF_VERSION exit /b 1
if exist "!VF_FOLDER!\shaders" set "VF_VERIFIED=1"
if exist "!VF_FOLDER!\vulkanshadercache" set "VF_VERIFIED=1"
if exist "!VF_FOLDER!\GraphicsSettings" set "VF_VERIFIED=1"
if "!VF_VERIFIED!"=="0" exit /b 1
exit /b 0

:: Force delete shader cache folders. Unlike the safe cleanup, this does not
:: compare against installed builds - every verified starcitizen_* folder is
:: offered, and deletion is preceded by a typed YES + re-verification.
:ForceDeleteShaderCache
echo.
echo =========================================
echo Force Delete Shader Cache
echo =========================================
echo.

if not exist "!SHADER_CACHE_ROOT!" (
    echo Error: Shader cache folder not found: "!SHADER_CACHE_ROOT!"
    echo Auto-detection failed. If using a custom Wine prefix, set SHADER_CACHE_ROOT.
    pause
    goto :eof
)

echo Shader cache root: "!SHADER_CACHE_ROOT!"
echo.
echo Scanning shader cache folders ^(only verified Star Citizen shader folders are offered^)...
echo.

:: Build the candidate list, skipping anything VerifyShaderFolder rejects.
:: Each candidate is registered as FD_<n> (full path) + FD_NAME_<n> (name),
:: with FD_LIST tracking the indices - same pattern as CleanupShaderCache.
set "FD_COUNT=0"
set "FD_LIST="
for /d %%D in ("!SHADER_CACHE_ROOT!\starcitizen_*") do (
    set "FD_FOLDER=%%~fD"
    set "FD_NAME=%%~nxD"
    call :VerifyShaderFolder "%%~fD"
    if errorlevel 1 (
        echo Skipping ^(not verified as a shader cache^): %%~nxD
    ) else (
        set /a FD_COUNT+=1
        set "FD_!FD_COUNT!=%%~fD"
        set "FD_NAME_!FD_COUNT!=%%~nxD"
        set "FD_LIST=!FD_LIST! !FD_COUNT!"
    )
)

if %FD_COUNT% equ 0 (
    echo.
    echo No verified shader cache folders found. Nothing to delete.
    pause
    goto :eof
)

echo.
echo The following shader cache folders were found:
for %%D in (!FD_LIST!) do (
    call :GetFolderSizeMB "!FD_%%D!" FSIZE
    echo   %%D. !FD_NAME_%%D!  ^(!FSIZE! MB^)
)
echo.

set /p SELECTION=Enter folder number^(s^) to delete ^(space-separated^), 'a' for all, or 0 to cancel: 
if "%SELECTION%"=="0" (
    echo Force delete cancelled.
    pause
    goto :eof
)
if "%SELECTION%"=="" (
    echo No selection made. Force delete cancelled.
    pause
    goto :eof
)

set "DELETE_LIST="
if /i "%SELECTION%"=="a" (
    set "DELETE_LIST=!FD_LIST!"
) else (
    for %%N in (!FD_LIST!) do (
        for %%S in (%SELECTION%) do (
            if "%%S"=="%%N" set "DELETE_LIST=!DELETE_LIST! %%N"
        )
    )
)

if "!DELETE_LIST!"=="" (
    echo No valid selections. Force delete cancelled.
    pause
    goto :eof
)

echo.
echo You are about to permanently DELETE these shader cache folder^(s^):
for %%D in (!DELETE_LIST!) do (
    echo   - !FD_NAME_%%D!
)
echo.
set /p CONFIRM=Type YES to confirm deletion, or anything else to cancel: 
if /i not "!CONFIRM!"=="YES" (
    echo Force delete cancelled.
    pause
    goto :eof
)

for %%D in (!DELETE_LIST!) do (
    call :VerifyShaderFolder "!FD_%%D!"
    if errorlevel 1 (
        echo Refusing to delete ^(verification failed^): !FD_NAME_%%D!
    ) else (
        rmdir /S /Q "!FD_%%D!"
        if exist "!FD_%%D!" (
            echo Error deleting: !FD_NAME_%%D!
        ) else (
            echo Deleted: !FD_NAME_%%D!
        )
    )
)
echo.
echo Done. The game will rebuild shaders from scratch on next launch.
pause
goto :eof
