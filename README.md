## Star Citizen Utility - Backup & Restore Tool
A comprehensive backup and restore utility for Star Citizen game configurations. It safely backs up your user settings, control keybindings, and character data across the different Star Citizen branches (LIVE, PTU, and TECH-PREVIEW). This is especially useful when transferring configurations between game branches or safeguarding your settings.

Two scripts provide identical functionality, one for each platform:

# Platform	Script
Windows	StarCitizen_UserConfig_Backup.bat  
Linux	StarCitizen_UserConfig_Backup.sh (LUG launcher / Wine prefix)  
# Features  
Automatic backup of user profiles and control settings  
Restore functionality with backup selection and destination choice  
Support for multiple Star Citizen branches (LIVE, PTU, TECH-PREVIEW)  
Fixed restore menu options: 1 (LIVE), 2 (PTU), 3 (TECH-PREVIEW)  
Timestamped backups organized by date and game version  
Automatic detection of installed Star Citizen branch versions  
Organized backup directory structure for easy management  
Create HOTFIX symbolic link to LIVE folder for alternative branch access  
Download and install StarStrings language pack directly from GitHub  
Continuous menu loop - perform multiple operations without restarting  
Enhanced error handling with clear user feedback  
Cross-platform backup compatibility - backups can be shared between Windows and Linux installs  
## Requirements
# Windows
CAUTION Administrator privileges (required to access Star Citizen installation files)
Star Citizen installed at: C:\Program Files\Roberts Space Industries\StarCitizen
# Linux
bash, zip, unzip, curl, python3
On CachyOS / Arch: sudo pacman -S zip unzip curl python
No administrator privileges required - everything runs inside your user's Wine prefix
Star Citizen installed via the LUG Helper (default prefix: ~/Games/star-citizen)  
## Setup Instructions - Windows
Place the batch file Copy StarCitizen_UserConfig_Backup.bat to your Documents folder.
Create a desktop shortcut
Right-click the batch file → Send to → Desktop (create shortcut)
Right-click the shortcut → Properties
Go to the Shortcut tab → Advanced button
Check "Run as administrator"
Click OK to save changes
Important - read before running This script requires administrative privileges to access Star Citizen program files. Please review the code within the batch file to ensure you are comfortable with its operations before granting administrator access.
Run the utility Double-click the shortcut to launch the main menu. After completing any operation, you'll be returned to the main menu to perform additional actions.
## Setup Instructions - Linux
Place the script Copy StarCitizen_UserConfig_Backup.sh anywhere convenient (e.g. your Documents folder).
Make it executable chmod +x StarCitizen_UserConfig_Backup.sh
Adjust the installation path (only if needed) The script targets the default LUG Helper prefix: ~/Games/star-citizen/drive_c/Program Files/Roberts Space Industries/StarCitizen
If your Star Citizen installation lives elsewhere, override the paths when running:

SC_BASE="/path/to/StarCitizen" BACKUP_ROOT="/path/to/backups" ./StarCitizen_UserConfig_Backup.sh  
Run the utility
./StarCitizen_UserConfig_Backup.sh  
After completing any operation, you'll be returned to the main menu to perform additional actions.  

# Main Menu Options
Option 1 - Backup Configuration
Backs up your current LIVE configuration to a timestamped compressed file.

Option 2 - Restore Configuration
First, you'll select which backup to restore:

Lists all available backups by date and version
Automatically selects if only one backup exists
Then, you'll select the restoration destination:

LIVE
PTU (if installed)
TECH-PREVIEW (if installed)
Restores your selected backup to the chosen Star Citizen branch.

Option 3 - Create HOTFIX Symbolic Link
Creates a HOTFIX folder that links to the LIVE folder.

How it works:

Checks if HOTFIX folder already exists (and removes it if valid)
Validates that any existing HOTFIX folder is empty before removal
Confirms LIVE folder is available before creating the link
Creates symbolic link: HOTFIX → LIVE
Prerequisites:

Windows: must run as administrator (already required). Linux: no special privileges needed.
LIVE folder must exist in Star Citizen installation
HOTFIX folder must not exist or must be empty
Option 4 - Download and install StarStrings language pack
Downloads the latest StarStrings release from GitHub and installs it into LIVE.

## How it works:

Fetches the latest release ZIP from https://github.com/MrKraken/StarStrings/releases/latest
Extracts the ZIP to a temporary folder
Copies the contained data folder into the LIVE root folder
Preserves an existing LIVE USER.cfg if present
If USER.cfg exists, appends g_language = english if needed
If USER.cfg does not exist, copies the package's USER.cfg into LIVE
Option 5 - Exit
Backup Location & Structure
Backups are stored as compressed .zip files and organized by date and game version.

Platform	Backup directory
Windows	%USERPROFILE%\Documents\SC_Config_Backups\
Linux	~/Documents/SC_Config_Backups/ (override with the BACKUP_ROOT environment variable)
Folder / file naming: YYYY_MM_DD_BranchVersion

Examples: 2026_04_19_Alpha_4.0.0, 2026_07_22_Alpha_4.9.0

The zip archives produced by both scripts share the same internal layout, so a backup taken on Windows can be restored on Linux and vice versa - handy for dual-boot setups.

   Folder structure: YYYY_MM_DD_BranchVersion
   Example: 2026_04_19_Alpha_4.0.0
