STAR CITIZEN UTILITY - Backup & Restore Tool

DESCRIPTION:
StarCitizen_Utility.bat is a comprehensive backup and restore utility for Star
Citizen game configurations. It allows you to safely backup your user settings,
control keybindings, and character data across different Star Citizen branches
(LIVE, PTU, and TECH-PREVIEW). This is especially useful when transferring
configurations between game branches or safeguarding your settings.

FEATURES:
  • Automatic backup of user profiles and control settings
  • Restore functionality to recover previous configurations
  • Support for multiple Star Citizen branches (LIVE, PTU, TECH-PREVIEW)
  • Timestamped backups organized by date and game version
  • Automatic detection of installed Star Citizen branch versions
  • Organized backup directory structure for easy management
  • Create HOTFIX symbolic link to LIVE folder for alternative branch access

REQUIREMENTS:
  • Administrator privileges (required to access Star Citizen installation files)
  • Star Citizen installed at: C:\Program Files\Roberts Space Industries\StarCitizen

SETUP INSTRUCTIONS:

1. PLACE THE BATCH FILE
   Copy StarCitizen_Utility.bat to your Documents folder
   (or keep it in its current location if already there)

2. CREATE A DESKTOP SHORTCUT
   • Right-click the batch file → Send to → Desktop (create shortcut)
   • Right-click the shortcut → Properties
   • Go to the Shortcut tab → Advanced button
   • Check "Run as administrator"
   • Click OK to save changes

3. IMPORTANT - READ BEFORE RUNNING
   This script requires administrative privileges to access Star Citizen program
   files. Please review the code within the batch file to ensure you are
   comfortable with its operations before granting administrator access.

4. RUN THE UTILITY
   Double-click the shortcut to launch the main menu with three options:
   
   Option 1 - Backup Configuration
      Backs up your current LIVE configuration to a timestamped compressed file
      
   Option 2 - Restore Configuration
      Restores a previous backup to your selected Star Citizen branch
      (LIVE, PTU, or TECH-PREVIEW if available)
      
   Option 3 - Create HOTFIX Symbolic Link
      Creates a HOTFIX folder that links to the LIVE folder
      
      How it works:
      • Checks if HOTFIX folder already exists (and removes it if valid)
      • Validates that any existing HOTFIX folder is empty before removal
      • Confirms LIVE folder is available before creating the link
      • Creates symbolic link: HOTFIX → LIVE
      
      Prerequisites:
      • Must run as administrator (already required)
      • LIVE folder must exist in Star Citizen installation
      • HOTFIX folder must not exist or must be empty

BACKUP LOCATION:
   Backups are automatically stored in:
   %USERPROFILE%\Documents\SC_Config_Backups\

   Folder structure: YYYY_MM_DD_BranchVersion
   Example: 2026_04_19_Alpha_4.0.0
