<#
 PowerShell GUI Launcher for RStudio Containers
 ---------------------------------------------
 This script prompts for username and password, then connects over SSH
 to start or create a Docker container, returning the URL for RStudio.

  - Open PowerShell console (not by double-clicking)
  - cd to script folder
  - Run: `PowerShell -ExecutionPolicy Bypass -File .\access_rstudio_gui.ps1 -STA`

 To make it double-clickable:
 1. Install ps2exe (if needed):
      Install-Module -Name ps2exe -Scope CurrentUser
 2. Compile to exe:
      Invoke-PS2EXE -InputFile .\access_rstudio_gui.ps1 -OutputFile .\IMPACT.exe
 3. Double-click the resulting `access-rstudio-gui.exe` to launch the GUI.


TODOs:
 - Think about adding individual users also for the Linux machine. This could use the username generated in the beginning!
 - Add logic to mount specific model folder that contains folders with a GitHub repo of a model if on remote host
 - Add logic to stop container locally and on remote host
 - Correctly setup user and group IDs to enable Git in the container
 - Add Information message that changes need to be pushed to the GitHub repo through RStudio in the browser
 - Ensure the script works both locally and on remote hosts
#>

# Parameter to detect if this is an elevated restart
param(
    [switch]$ElevatedRestart,
    [switch]$PS7Requested
)

# Global debug flag - controls visibility of debug messages
$script:DebugMode = $false
$script:UseDirectSshForDocker = $false  # Flag for Docker context SSH limitations
$script:UserWantsPS7 = $false  # Flag to track PowerShell 7 preference for elevation

# Debug write function that respects the global debug flag
function Write-Debug-Message {
    param(
        [string]$Message,
        [string]$ForegroundColor = "Magenta"
    )
    if ($script:DebugMode) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

# Function to center forms on the screen where the cursor is currently located
function Set-FormCenterOnCurrentScreen {
    param(
        [System.Windows.Forms.Form]$Form
    )
    
    try {
        # Add necessary Windows API types once
        if (-not ("Win32" -as [type])) {
            Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        using System.Drawing;
        
        public struct POINT {
            public int X;
            public int Y;
        }
        
        public struct RECT {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }
        
        public class Win32 {
            [DllImport("user32.dll")]
            public static extern bool GetCursorPos(out POINT lpPoint);
            
            [DllImport("user32.dll")]
            public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);
            
            [DllImport("user32.dll")]
            public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
        }
        
        [StructLayout(LayoutKind.Sequential)]
        public struct MONITORINFO {
            public uint cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
        }
"@
        }
        
        # Get cursor position
        $cursorPos = New-Object POINT
        [Win32]::GetCursorPos([ref]$cursorPos) | Out-Null
        
        # Get monitor from cursor position
        $monitor = [Win32]::MonitorFromPoint($cursorPos, 2) # MONITOR_DEFAULTTONEAREST
        
        # Get monitor info
        $monitorInfo = New-Object MONITORINFO
        $monitorInfo.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($monitorInfo)
        [Win32]::GetMonitorInfo($monitor, [ref]$monitorInfo) | Out-Null
        
        # Calculate center position on the current monitor
        $screenWidth = $monitorInfo.rcWork.Right - $monitorInfo.rcWork.Left
        $screenHeight = $monitorInfo.rcWork.Bottom - $monitorInfo.rcWork.Top
        $screenLeft = $monitorInfo.rcWork.Left
        $screenTop = $monitorInfo.rcWork.Top
        
        $formWidth = $Form.Width
        $formHeight = $Form.Height
        
        $centerX = $screenLeft + (($screenWidth - $formWidth) / 2)
        $centerY = $screenTop + (($screenHeight - $formHeight) / 2)
        
        # Set form position
        $Form.StartPosition = 'Manual'
        $Form.Location = New-Object System.Drawing.Point([int]$centerX, [int]$centerY)
        
        Write-Debug-Message "[DEBUG] Form centered on current screen at: $([int]$centerX), $([int]$centerY)"
        
    } catch {
        Write-Debug-Message "[DEBUG] Failed to center form on current screen, falling back to CenterScreen: $($_.Exception.Message)"
        $Form.StartPosition = 'CenterScreen'
    }
}

#--------------------------------------#
#   POWERSHELL VERSION CHECK            #
#--------------------------------------#

Write-Debug-Message "[DEBUG] Starting PowerShell version check..."
Write-Debug-Message "[DEBUG] Current PowerShell version: $($PSVersionTable.PSVersion)"
Write-Debug-Message "[DEBUG] PowerShell edition: $($PSVersionTable.PSEdition)"
Write-Debug-Message "[DEBUG] Elevated restart parameter: $ElevatedRestart"
Write-Debug-Message "[DEBUG] PS7 requested parameter: $PS7Requested"

# Show PS7 message if this is an elevated restart with PS7 requested
if ($ElevatedRestart -and $PS7Requested) {
    Write-Host ""
    Write-Host "  [INFO] Restarted with elevated privileges as requested" -ForegroundColor Green
    Write-Host "  [INFO] PowerShell 7 preference noted - continuing with current PowerShell version" -ForegroundColor Cyan
    Write-Host ""
}

# Check PowerShell version and recommend PowerShell 7 if needed (skip on elevated restart)
if ($PSVersionTable.PSVersion.Major -lt 6 -and -not $ElevatedRestart) {
    Write-Debug-Message "[DEBUG] Detected Windows PowerShell (version < 6), checking for PowerShell 7..."
    $pwshAvailable = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    Write-Debug-Message "[DEBUG] PowerShell 7 availability check: $(if($pwshAvailable) { 'Available' } else { 'Not found' })"
    
    if ($pwshAvailable) {
        Write-Debug-Message "[DEBUG] PowerShell 7 found at: $($pwshAvailable.Source)"
        Write-Host ""
        Write-Host "  [NOTICE] You're running Windows PowerShell 5.1" -ForegroundColor Yellow
        Write-Host "  PowerShell 7 is available on your system and provides better compatibility." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  Recommendation: Use PowerShell 7 for the best experience." -ForegroundColor Cyan
        Write-Host "  Example: pwsh.exe -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -ForegroundColor Cyan
        Write-Host ""
        
        # Check if we're running as compiled EXE to determine input method
        $scriptPath = $MyInvocation.MyCommand.Path
        $isCompiledEXE = ($null -eq $scriptPath) -or ($scriptPath -like "*.exe")
        
        if ($isCompiledEXE) {
            # For compiled EXE, use Windows Forms dialog instead of Read-Host
            Write-Debug-Message "[DEBUG] Compiled EXE detected, using Windows Forms dialog for PowerShell 7 choice"
            Add-Type -AssemblyName System.Windows.Forms
            $result = [System.Windows.Forms.MessageBox]::Show(
                "PowerShell 7 is available and provides better compatibility.`n`nFor compiled executables, we'll continue with the current PowerShell version.`n`nWould you like to continue?",
                "PowerShell Version Notice",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            $usePS7 = if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { "y" } else { "n" }
            Write-Debug-Message "[DEBUG] User PowerShell 7 choice via dialog: $usePS7"
        } else {
            # For script files, use Read-Host as normal
            $usePS7 = Read-Host "  Would you like to restart with PowerShell 7 now? (y/n)"
            Write-Debug-Message "[DEBUG] User PowerShell 7 restart choice: $usePS7"
        }
        if ($usePS7 -match "^[Yy]") {
            Write-Debug-Message "[DEBUG] User chose to restart with PowerShell 7"
            Write-Host "  Restarting with PowerShell 7..." -ForegroundColor Green
            
            # Store the PS7 preference for later use
            $script:UserWantsPS7 = $true
            
            try {
                # Detect if we're running as a compiled EXE and get the correct path
                $scriptPath = $MyInvocation.MyCommand.Path
                $isCompiledEXE = ($null -eq $scriptPath) -or ($scriptPath -like "*.exe")
                
                if ($isCompiledEXE) {
                    # For compiled EXE, we can't restart with pwsh, we need to use the EXE directly
                    $executablePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                    Write-Debug-Message "[DEBUG] Compiled EXE detected, restarting EXE directly: $executablePath"
                    Write-Host "  Note: For compiled executables, continuing with current PowerShell version..." -ForegroundColor Cyan
                    Write-Host "  PowerShell 7 preference will be remembered for admin restart." -ForegroundColor Cyan
                    # Don't restart, just continue execution with PS7 preference stored
                } else {
                    # For script files, restart with PowerShell 7
                    Write-Debug-Message "[DEBUG] Attempting to start PowerShell 7 with arguments: -ExecutionPolicy Bypass -File '$scriptPath'"
                    Start-Process "pwsh" -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`"" -Wait
                    Write-Debug-Message "[DEBUG] PowerShell 7 restart successful, exiting current session"
                    exit
                }
            } catch {
                Write-Debug-Message "[DEBUG] PowerShell 7 restart failed: $($_.Exception.Message)"
                Write-Host "  Failed to restart with PowerShell 7. Continuing with current PowerShell version..." -ForegroundColor Yellow
            }
        } else {
            Write-Debug-Message "[DEBUG] User chose to continue with Windows PowerShell 5.1"
            Write-Host "  Continuing with Windows PowerShell 5.1..." -ForegroundColor Yellow
        }
    } else {
        Write-Debug-Message "[DEBUG] PowerShell 7 not available, showing installation recommendation"
        Write-Host ""
        Write-Host "  [RECOMMENDATION] PowerShell 7 Installation" -ForegroundColor Yellow
        Write-Host "  ===========================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  You're using Windows PowerShell 5.1. For better compatibility and features," -ForegroundColor White
        Write-Host "  we recommend installing PowerShell 7 (the modern, cross-platform version)." -ForegroundColor White
        Write-Host ""
        Write-Host "  Benefits of PowerShell 7:" -ForegroundColor Cyan
        Write-Host "  ? Better module compatibility" -ForegroundColor White
        Write-Host "  ? Improved performance" -ForegroundColor White
        Write-Host "  ? Enhanced error handling" -ForegroundColor White
        Write-Host "  ? Regular updates and security patches" -ForegroundColor White
        Write-Host ""
        Write-Host "  Download PowerShell 7:" -ForegroundColor Green
        Write-Host "  https://github.com/PowerShell/PowerShell/releases/latest" -ForegroundColor Blue
        Write-Host ""
        Write-Host "  Quick Install Options:" -ForegroundColor Green
        Write-Host "  1. Via Microsoft Store: Search 'PowerShell'" -ForegroundColor White
        Write-Host "  2. Via Winget: winget install Microsoft.PowerShell" -ForegroundColor White
        Write-Host "  3. Via Direct Download from the link above" -ForegroundColor White
        Write-Host ""
        Write-Host "  After installation, run: pwsh.exe -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -ForegroundColor Cyan
        Write-Host ""
        
        # Check if we're running as compiled EXE to determine input method
        $scriptPath = $MyInvocation.MyCommand.Path
        $isCompiledEXE = ($null -eq $scriptPath) -or ($scriptPath -like "*.exe")
        
        if ($isCompiledEXE) {
            # For compiled EXE, use Windows Forms dialog
            Add-Type -AssemblyName System.Windows.Forms
            $result = [System.Windows.Forms.MessageBox]::Show(
                "PowerShell 7 is recommended for better compatibility.`n`nWould you like to open the download page in your browser?",
                "PowerShell 7 Download",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            $openDownload = if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { "y" } else { "n" }
        } else {
            # For script files, use Read-Host
            $openDownload = Read-Host "  Open PowerShell 7 download page in browser? (y/n)"
        }
        if ($openDownload -match "^[Yy]") {
            try {
                Start-Process "https://github.com/PowerShell/PowerShell/releases/latest"
                Write-Host "  Download page opened in your default browser." -ForegroundColor Green
                Write-Host "  This application will continue with Windows PowerShell 5.1 for now." -ForegroundColor Yellow
            } catch {
                Write-Host "  Could not open browser. Please manually visit:" -ForegroundColor Yellow
                Write-Host "  https://github.com/PowerShell/PowerShell/releases/latest" -ForegroundColor Blue
            }
        }
        
        Write-Host ""
        Write-Host "  Continuing with Windows PowerShell 5.1..." -ForegroundColor Yellow
    }
    
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "  [SUCCESS] Running PowerShell $($PSVersionTable.PSVersion) (Core)" -ForegroundColor Green
    Write-Host ""
}

#--------------------------------------#
#   ADMINISTRATOR PRIVILEGE CHECK       #
#--------------------------------------#

Write-Debug-Message "[DEBUG] Checking administrator privileges..."

# Check if running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

Write-Debug-Message "[DEBUG] Administrator privileges: $(if($isAdmin) { 'Present' } else { 'Missing' })"

# Also check current user and process info for debugging
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$processInfo = [System.Diagnostics.Process]::GetCurrentProcess()
Write-Debug-Message "[DEBUG] Current user: $currentUser"
Write-Debug-Message "[DEBUG] Process name: $($processInfo.ProcessName)"
Write-Debug-Message "[DEBUG] Process path: $($processInfo.MainModule.FileName)"

if (-not $isAdmin) {
    Write-Debug-Message "[DEBUG] Administrator privileges required, attempting elevation..."
    Write-Host ""
    Write-Host "NOTICE: This script requires administrator privileges for Docker operations."
    Write-Host "Attempting to restart with elevated privileges..."
    Write-Host ""
    
    try {
        # Get the current script path
        $scriptPath = $MyInvocation.MyCommand.Path
        Write-Debug-Message "[DEBUG] Current script path: $scriptPath"
        
        # Detect if we're running as a compiled EXE
        $isCompiledEXE = ($null -eq $scriptPath) -or ($scriptPath -like "*.exe")
        Write-Debug-Message "[DEBUG] Is compiled EXE: $isCompiledEXE"
        
        if ($isCompiledEXE) {
            # For compiled EXE, check if user wants PowerShell 7 and if it's available
            if ($script:UserWantsPS7) {
                # Check if PowerShell 7 is available and if the original script exists
                $pwshAvailable = Get-Command pwsh.exe -ErrorAction SilentlyContinue
                $scriptDir = Split-Path $executablePath -Parent
                $originalScript = Join-Path $scriptDir "access_rstudio_gui.ps1"
                
                if ($pwshAvailable -and (Test-Path $originalScript)) {
                    Write-Host "  User requested PowerShell 7 - restarting with PowerShell 7..." -ForegroundColor Green
                    Write-Debug-Message "[DEBUG] Restarting with PowerShell 7: $($pwshAvailable.Source)"
                    Write-Debug-Message "[DEBUG] Using script: $originalScript"
                    
                    # Restart with PowerShell 7 using the original script
                    Start-Process $pwshAvailable.Source -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$originalScript`" -ElevatedRestart -PS7Requested"
                    exit
                } else {
                    Write-Host "  PowerShell 7 requested but not available or script not found." -ForegroundColor Yellow
                    Write-Host "  Continuing with compiled executable..." -ForegroundColor Yellow
                }
            }
            
            # For compiled EXE, use the current process executable path
            $executablePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            Write-Debug-Message "[DEBUG] Compiled EXE path: $executablePath"
            
            Write-Host "  Restarting compiled executable with elevated privileges..." -ForegroundColor Cyan
            Write-Host "  Please confirm the UAC prompt when it appears." -ForegroundColor Yellow
            Write-Host ""
            
            # Add a pause to ensure user sees the message
            Start-Sleep -Seconds 2
            
            # Check if user wanted PowerShell 7 and pass it as parameter
            $ps7Args = if ($script:UserWantsPS7) { "-ElevatedRestart -PS7Requested" } else { "-ElevatedRestart" }
            Write-Debug-Message "[DEBUG] Elevation arguments: $ps7Args"
            
            # Restart the EXE with elevated privileges and parameters
            Start-Process $executablePath -Verb RunAs -ArgumentList $ps7Args
            exit
        } elseif ($scriptPath) {
            Write-Debug-Message "[DEBUG] Running as script file, proceeding with elevation"
            # Use the current PowerShell executable for restart
            $currentPSExecutable = if ($PSVersionTable.PSVersion.Major -ge 6) { 
                "pwsh" 
            } else { 
                "PowerShell" 
            }
            Write-Debug-Message "[DEBUG] Selected PowerShell executable for elevation: $currentPSExecutable"
            
            Write-Host "  Restarting with elevated privileges using: $currentPSExecutable" -ForegroundColor Cyan
            
            # Restart with elevated privileges using the current PowerShell version and pass the parameter
            Start-Process $currentPSExecutable -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`" -ElevatedRestart"
            exit
        } else {
            # If running interactively 
            Write-Host ""
            Write-Host "Please restart this application as Administrator."
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("This application requires Administrator privileges to manage Docker containers.`n`nPlease right-click and select 'Run as Administrator'.", "Administrator Required", "OK", "Warning")
            exit 1
        }
    } catch {
        Write-Host ""
        Write-Host "Could not automatically elevate privileges."
        Write-Host "Please manually restart this application as Administrator."
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("This application requires Administrator privileges to manage Docker containers.`n`nPlease right-click and select 'Run as Administrator'.", "Administrator Required", "OK", "Warning")
        exit 1
    }
} else {
    Write-Debug-Message "[DEBUG] Administrator privileges confirmed, continuing with script execution"
    Write-Host ""
    Write-Host "[SUCCESS] Running with Administrator privileges" -ForegroundColor Green
    
    # Additional check for compiled EXE to ensure we're running in the right context
    $scriptPath = $MyInvocation.MyCommand.Path
    $isCompiledEXE = ($null -eq $scriptPath) -or ($scriptPath -like "*.exe")
    if ($isCompiledEXE) {
        $executablePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        Write-Debug-Message "[DEBUG] Running as elevated compiled EXE: $executablePath"
        Write-Host "[INFO] Compiled executable running with administrator privileges" -ForegroundColor Cyan
    }
    Write-Host ""
}

#--------------------------------------#
#   TERMINAL COLOR CONFIGURATION       #
#--------------------------------------#

Write-Debug-Message "[DEBUG] Configuring terminal colors..."

# Set terminal background to black and configure color scheme
try {
    $Host.UI.RawUI.BackgroundColor = "Black"
    $Host.UI.RawUI.ForegroundColor = "White"
    
    # Increase terminal font size if possible
    try {
        # Try to access font properties (may not work in all terminal types)
        if ($Host.UI.RawUI.WindowSize) {
            # Set a larger buffer size for better readability
            $currentSize = $Host.UI.RawUI.BufferSize
            if ($currentSize.Width -lt 120) {
                $newSize = New-Object System.Management.Automation.Host.Size(120, $currentSize.Height)
                $Host.UI.RawUI.BufferSize = $newSize
            }
            Write-Debug-Message "[DEBUG] Terminal buffer size configured for better readability"
        }
    } catch {
        Write-Debug-Message "[DEBUG] Could not modify terminal font/buffer settings: $($_.Exception.Message)"
    }
    
    Clear-Host
    Write-Debug-Message "[DEBUG] Terminal colors configured successfully (Black background, White foreground)"
} catch {
    Write-Debug-Message "[DEBUG] Terminal color configuration failed: $($_.Exception.Message)"
    # Fallback if terminal doesn't support color changes
    Write-Host "Note: Terminal color configuration not supported on this system" -ForegroundColor Yellow
}

#--------------------------------------#
#   STEP 0: SETUP AND PRE-REQUISITES   #
#--------------------------------------#

Write-Debug-Message "[DEBUG] STEP 0: Initializing setup and prerequisites..."

# Ensure Windows Forms app environment
Write-Debug-Message "[DEBUG] Loading Windows Forms assemblies..."
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
Write-Debug-Message "[DEBUG] Windows Forms environment configured successfully"


#----------------------------------------------#
#   STEP 1: PROMPT FOR USERNAME AND PASSWORD   #
#----------------------------------------------#

Write-Debug-Message "[DEBUG] STEP 1: Starting username and password collection..."

Write-Host "
                                                                     ,----,                
                  ____  ,-.----.                                   ,/   .`|                
   ,---,        ,'  , `.\    /  \     ,---,         ,----..      ,`   .'  :                
,`--.' |     ,-+-,.' _ ||   :    \   '  .' \       /   /   \   ;    ;     /                
|   :  :  ,-+-. ;   , |||   |  .\ : /  ;    '.    |   :     :.'___,/    ,'                 
:   |  ' ,--.'|'   |  ;|.   :  |: |:  :       \   .   |  ;. /|    :     |                  
|   :  ||   |  ,', |  ':|   |   \ ::  |   /\   \  .   ; /--` ;    |.';  ;                  
'   '  ;|   | /  | |  |||   : .   /|  :  ' ;.   : ;   | ;    `----'  |  |                  
|   |  |'   | :  | :  |,;   | |`-' |  |  ;/  \   \|   : |        '   :  ;                  
'   :  ;;   . |  ; |--' |   | ;    '  :  | \  \ ,'.   | '___     |   |  '                  
|   |  '|   : |  | ,    :   ' |    |  |  '  '--'  '   ; : .'|    '   :  |                  
'   :  ||   : '  |/     :   : :    |  :  :        '   | '/  :    ;   |.'                   
;   |.' ;   | |`-'      |   | :    |  | ,'        |   :    /     '---'                     
'---'   |   ;/          `---'.|    `--''           \   \ .'                                
        '---'             `---`              ,--.   `---`
                                           ,--.'|  ,----..      ,---,                      
                                       ,--,:  : | /   /   \   .'  .' `\                    
                                    ,`--.'`|  ' :|   :     :,---.'     \                   
                                    |   :  :  | |.   |  ;. /|   |  .`\  |                  
                                    :   |   \ | :.   ; /--` :   : |  '  |                  
                                    |   : '  '; |;   | ;    |   ' '  ;  :                  
                                    '   ' ;.    ;|   : |    '   | ;  .  |                  
                                    |   | | \   |.   | '___ |   | :  |  '                  
                                    '   : |  ; .''   ; : .'|'   : | /  ;                   
                                    |   | '`--'  '   | '/  :|   | '` ,/                    
                                    '   : |      |   :    / ;   :  .'                      
                                    ;   |.'       \   \ .'  |   ,.'                        
                                    '---'  ____    `---`    '---'        ,--.              
  ,----..       ,---,.,-.----.           ,'  , `.   ,---,              ,--.'|              
 /   /   \    ,'  .' |\    /  \       ,-+-,.' _ |  '  .' \         ,--,:  : |        ,---, 
|   :     : ,---.'   |;   :    \   ,-+-. ;   , || /  ;    '.    ,`--.'`|  ' :       /_ ./| 
.   |  ;. / |   |   .'|   | .\ :  ,--.'|'   |  ;|:  :       \   |   :  :  | | ,---, |  ' : 
.   ; /--`  :   :  |-,.   : |: | |   |  ,', |  '::  |   /\   \  :   |   \ | :/___/ \.  : | 
;   | ;  __ :   |  ;/||   |  \ : |   | /  | |  |||  :  ' ;.   : |   : '  '; | .  \  \ ,' ' 
|   : |.' .'|   :   .'|   : .  / '   | :  | :  |,|  |  ;/  \   \'   ' ;.    ;  \  ;  `  ,' 
.   | '_.' :|   |  |-,;   | |  \ ;   . |  ; |--' '  :  | \  \ ,'|   | | \   |   \  \    '  
'   ; : \  |'   :  ;/||   | ;\  \|   : |  | ,    |  |  '  '--'  '   : |  ; .'    '  \   |  
'   | '/  .'|   |    \:   ' | \.'|   : '  |/     |  :  :        |   | '`--'       \  ;  ;  
|   :    /  |   :   .':   : :-'  ;   | |`-'      |  | ,'        '   : |            :  \  \ 
 \   \ .'   |   | ,'  |   |.'    |   ;/          `--''          ;   |.'             \  ' ; 
  `---`     `----'    `---'      '---'                          '---'                `--`
                                                                                           "
Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "================================================"
Write-Host "  IMPACT NCD Germany - Docker Container Manager"
Write-Host "================================================"
Write-Host ""
Write-Host ""
Write-Host ""
Write-Host "Initializing application..."
Write-Host ""

Write-Debug-Message "[DEBUG] Creating main credentials form..."

# Build the form
$form = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Remote Access - IMPACT NCD Germany'
    Size = New-Object System.Drawing.Size(430,300)
    StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}

Write-Debug-Message "[DEBUG] Adding form controls (labels, textboxes, buttons)..."

# Instruction rich text box with formatting
$rtbInstruction = New-Object System.Windows.Forms.RichTextBox -Property @{ 
    Location = New-Object System.Drawing.Point(10,10)
    Size = New-Object System.Drawing.Size(380,120)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
    ReadOnly = $true
    BorderStyle = 'None'
    BackColor = $form.BackColor
    ScrollBars = 'None'
}

# Add formatted text
$rtbInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$rtbInstruction.AppendText("Please enter a username and a password!")
$rtbInstruction.AppendText("`n`n")

$rtbInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$rtbInstruction.SelectionColor = [System.Drawing.Color]::DarkRed
$rtbInstruction.AppendText("Important:")
$rtbInstruction.SelectionColor = [System.Drawing.Color]::Black
$rtbInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$rtbInstruction.AppendText("`nThe username will be used for an SSH key and for container management.`nThe password will be used to login to your RStudio Server session.`n`n")

$rtbInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Regular)
$rtbInstruction.SelectionColor = [System.Drawing.Color]::DarkGray
$rtbInstruction.AppendText("(Username will be normalized: spaces removed, lowercase)")

$form.Controls.Add($rtbInstruction)

# Username label and textbox
$labelUser = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Username:'
    Location = New-Object System.Drawing.Point(10,140)
    Size = New-Object System.Drawing.Size(100,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$form.Controls.Add($labelUser)
$textUser = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(120,140)
    Size = New-Object System.Drawing.Size(250,20)
}
$form.Controls.Add($textUser)

# Password label and textbox
$labelPass = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Password:'
    Location = New-Object System.Drawing.Point(10,170)
    Size = New-Object System.Drawing.Size(100,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$form.Controls.Add($labelPass)
$textPass = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(120,170)
    Size = New-Object System.Drawing.Size(250,20)
}
$form.Controls.Add($textPass)

# OK and Cancel buttons
$buttonOK = New-Object System.Windows.Forms.Button -Property @{
    Text = 'OK'
    Location = New-Object System.Drawing.Point(200,210)
    Size = New-Object System.Drawing.Size(75,30)
}
$form.Controls.Add($buttonOK)

$buttonCancel = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Cancel'
    Location = New-Object System.Drawing.Point(290,210)
    Size = New-Object System.Drawing.Size(75,30)
    DialogResult = [System.Windows.Forms.DialogResult]::Cancel
}
$form.Controls.Add($buttonCancel)

# Set default buttons
$form.AcceptButton = $buttonOK
$form.CancelButton = $buttonCancel

# Set focus to username field when form is shown
$form.Add_Shown({
    $textUser.Focus()
})

# Add validation for OK button click
$buttonOK.Add_Click({
    # Validate username
    if ([string]::IsNullOrWhiteSpace($textUser.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a username.', 'Error', 'OK', 'Error')
        Write-Host ""
        Write-Host "ERROR: No username provided"
        Write-Host ""
        $textUser.Focus()
        return
    }
    
    # Validate password
    if ([string]::IsNullOrWhiteSpace($textPass.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a password.', 'Error', 'OK', 'Error')
        Write-Host ""
        Write-Host "ERROR: No password provided"
        Write-Host ""
        $textPass.Focus()
        return
    }
    
    # If validation passes, close the dialog with OK result
    $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Close()
})

# Show the dialog and capture the result
Write-Debug-Message "[DEBUG] Displaying credentials form to user..."
$result = $form.ShowDialog()
Write-Debug-Message "[DEBUG] Credentials form result: $result"

# Initialize variables
$USERNAME = $null
$PASSWORD = $null

# If user clicked OK, save the values
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Debug-Message "[DEBUG] Processing user credentials..."
    # Normalize username: remove spaces and convert to lowercase for consistency
    $originalUsername = $textUser.Text.Trim()
    Write-Debug-Message "[DEBUG] Original username: '$originalUsername'"
    # Fix: Ensure USERNAME is always a string, not an array
    $USERNAME = ($originalUsername -replace '\s+', '').ToLower()
    $PASSWORD = $textPass.Text
    Write-Debug-Message "[DEBUG] Normalized username: '$USERNAME'"
    Write-Debug-Message "[DEBUG] Password length: $($PASSWORD.Length) characters"
    
    # Validate that USERNAME is not empty after normalization
    if ([string]::IsNullOrWhiteSpace($USERNAME)) {
        Write-Debug-Message "[DEBUG] Username validation failed - empty after normalization"
        Write-Host ""
        Write-Host "[ERROR] Username became empty after normalization" -ForegroundColor Red
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show('Username cannot be empty after removing spaces.', 'Invalid Username', 'OK', 'Error')
        exit 1
    }
    
    Write-Debug-Message "[DEBUG] Credentials validation successful"
    Write-Host ""
    Write-Host "[SUCCESS] Credentials collected successfully" -ForegroundColor Green
    if ($originalUsername -ne $USERNAME) {
        Write-Host "  Original Username: $originalUsername"
        Write-Host "  Normalized Username: $USERNAME (spaces removed, lowercase)"
    } else {
        Write-Host "  Username: $USERNAME"
    }
    Write-Host "  Password: $PASSWORD"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "[ERROR] User cancelled the dialog - no credentials provided" -ForegroundColor Red -ForegroundColor Red
    Write-Host ""
    exit 0
}


#-------------------------------------------------#
#   STEP 2: SETUP AND PROMPT FOR GitHub SSH KEY   #
#-------------------------------------------------#

Write-Debug-Message "[DEBUG] STEP 2: Starting SSH key setup for GitHub integration..."

# Only proceed if user provided credentials
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Debug-Message "[DEBUG] Credentials validated, proceeding with SSH key setup"
    Write-Host ""
    Write-Host "================================================"
    Write-Host "  STEP 2: SSH Key Setup for GitHub Integration"
    Write-Host "================================================"
    Write-Host ""
    
    # Define SSH key paths (individual per user)
    $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
    $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME.pub"
    
    Write-Debug-Message "[DEBUG] SSH key paths defined:"
    Write-Debug-Message "[DEBUG]   Private key: $sshKeyPath"
    Write-Debug-Message "[DEBUG]   Public key: $sshPublicKeyPath"

    # Check if SSH key already exists
    Write-Debug-Message "[DEBUG] Checking for existing SSH keys..."
    $privateKeyExists = Test-Path $sshKeyPath
    $publicKeyExists = Test-Path $sshPublicKeyPath
    Write-Debug-Message "[DEBUG] Private key exists: $privateKeyExists"
    Write-Debug-Message "[DEBUG] Public key exists: $publicKeyExists"
    
    if ((Test-Path $sshKeyPath) -and (Test-Path $sshPublicKeyPath)) {
        Write-Debug-Message "[DEBUG] Both SSH keys found, using existing keys"
        Write-Host "[INFO] SSH key already exists" -ForegroundColor Cyan
        Write-Host "  Location: $sshKeyPath"
        Write-Host ""

        # Display public key to user
        $publicKey = Get-Content $sshPublicKeyPath
    
        Write-Host ""
        Write-Host "The following Public Key will be used:"
        Write-Host "----------------------------------------"
        Write-Host $publicKey
        Write-Host "----------------------------------------"
        Write-Host ""
        Write-Host "If you are not able to authenticate with GitHub:"
        Write-Host "1. Go to GitHub -> Settings -> SSH and GPG keys"  
        Write-Host "2. Check existing SSH keys"
        Write-Host "3. Compare to the key above and update if needed"
        Write-Host "================================================"
        Write-Host ""

    } else {

        Write-Host "[INFO] Generating new SSH key for Docker operations..." -ForegroundColor Cyan
        Write-Host ""
        Write-Debug-Message "[DEBUG] SSH keys not found, generating new keys..."
        
        # Ensure .ssh directory exists
        $sshDir = "$HOME\.ssh"
        Write-Debug-Message "[DEBUG] Checking SSH directory: $sshDir"
        if (-not (Test-Path $sshDir)) {
            Write-Debug-Message "[DEBUG] SSH directory does not exist, creating it..."
            New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
            Write-Debug-Message "[DEBUG] SSH directory created successfully"
            Write-Host ""
            Write-Host "  Created .ssh directory"
            Write-Host ""
        } else {
            Write-Debug-Message "[DEBUG] SSH directory already exists"
        }
        
        # Generate the SSH key (without passphrase for automation)
        Write-Debug-Message "[DEBUG] Preparing SSH key generation parameters..."
        Write-Host "  Generating SSH key with parameters:"
        Write-Host "  - Type: ed25519"
        Write-Host "  - Comment: IMPACT_$USERNAME"  
        Write-Host "  - File: $HOME\.ssh\id_ed25519_$USERNAME"
        Write-Host ""
        
        # Use proper argument array to avoid parameter parsing issues
        $sshKeyGenArgs = @(
            '-t', 'ed25519',
            '-C', "IMPACT_$USERNAME",
            '-f', "$HOME\.ssh\id_ed25519_$USERNAME",
            '-N', '',
            '-q'  # Quiet mode to suppress output
        )
        
        Write-Debug-Message "[DEBUG] SSH key generation arguments: $($sshKeyGenArgs -join ' ')"
        
        # Execute ssh-keygen with proper argument handling
        try {
            Write-Debug-Message "[DEBUG] Executing ssh-keygen command..."
            & ssh-keygen @sshKeyGenArgs
            $keyGenResult = $LASTEXITCODE
            Write-Debug-Message "[DEBUG] ssh-keygen exit code: $keyGenResult"
        } catch {
            Write-Debug-Message "[DEBUG] ssh-keygen execution exception: $($_.Exception.Message)"
            Write-Host ""
            Write-Host "  [ERROR] ssh-keygen execution failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            $keyGenResult = 1
        }
        
        # Check if SSH key generation was successful
        Write-Debug-Message "[DEBUG] Validating SSH key generation results..."
        $publicKeyGenerated = Test-Path "$HOME\.ssh\id_ed25519_$USERNAME.pub"
        Write-Debug-Message "[DEBUG] Public key file exists after generation: $publicKeyGenerated"
        
        if ($keyGenResult -eq 0 -and (Test-Path "$HOME\.ssh\id_ed25519_$USERNAME.pub")) {
            Write-Debug-Message "[DEBUG] SSH key generation successful"
            Write-Host ""
            Write-Host "[SUCCESS] New SSH key generated successfully!" -ForegroundColor Green
            Write-Host "  Private key: $HOME\.ssh\id_ed25519_$USERNAME"
            Write-Host "  Public key: $HOME\.ssh\id_ed25519_$USERNAME.pub"
            Write-Host ""
        } else {
            Write-Debug-Message "[DEBUG] SSH key generation failed - Exit code: $keyGenResult, Public key exists: $(Test-Path "$HOME\.ssh\id_ed25519_$USERNAME.pub")"
            Write-Host ""
            Write-Host "[ERROR] Failed to generate new SSH key!" -ForegroundColor Red
            Write-Host "  Exit code: $keyGenResult"
            Write-Host "  Expected public key at: $HOME\.ssh\id_ed25519_$USERNAME.pub"
            Write-Host ""
            exit 1
        }
        
        if (Test-Path $sshPublicKeyPath) {
            Write-Host ""
            Write-Host "[SUCCESS] Failsafe check: SSH key generated successfully!" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "[ERROR] Failed to generate SSH key!" -ForegroundColor Red
            Write-Host ""
            exit 1
        }

        $publicKey = Get-Content $sshPublicKeyPath

        # Show message box with public key only if new key was created
        $message = "It seems like you did not have an SSH key set up for Docker and GitHub.`n`n" +
                   "A new SSH public key has been generated.`n`n" +
                   "The new key is here: $sshPublicKeyPath`n`n" +
                   "You need to add this key to your GitHub account to enable SSH access.`n`n" +
                   "Please go to:`nGitHub -> Settings -> SSH and GPG keys -> New SSH key`n`n" +
                   "Enter a title/name for the SSH key and paste the key into the 'Key' field.`n`n" +
                   "Save the key. Done!`n`n" +
                   "The key has been copied to your clipboard and will be shown in a separate window for manual copying."
        
        # Copy to clipboard
        try {
            $publicKey | Set-Clipboard | Out-Null
            Write-Host ""
            Write-Host "[SUCCESS] Public key copied to clipboard!" -ForegroundColor Green
            Write-Host ""
        } catch {
            Write-Host ""
            Write-Host "[WARNING] Could not copy to clipboard, but key will be displayed." -ForegroundColor Yellow
            Write-Host ""
        }

        # Show the initial message box
        [System.Windows.Forms.MessageBox]::Show($message, 'SSH Key Setup', 'OK', 'Information') | Out-Null

        # Create a modern, well-designed dialog for SSH key display
        $formKeyDisplay = New-Object System.Windows.Forms.Form -Property @{ 
            Text = 'SSH Public Key - GitHub Integration'
            Size = New-Object System.Drawing.Size(800,500)
            FormBorderStyle = 'FixedDialog'
            MaximizeBox = $false
            MinimizeBox = $false
            BackColor = [System.Drawing.Color]::White
        }
        Set-FormCenterOnCurrentScreen -Form $formKeyDisplay

        # Title label with better styling
        $labelTitle = New-Object System.Windows.Forms.Label -Property @{ 
            Text = "SSH Public Key Generated"
            Location = New-Object System.Drawing.Point(20,15)
            Size = New-Object System.Drawing.Size(760,35)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 14, [System.Drawing.FontStyle]::Bold)
            ForeColor = [System.Drawing.Color]::DarkBlue
            TextAlign = 'MiddleCenter'
        }
        $formKeyDisplay.Controls.Add($labelTitle)

        # Instruction label with better formatting and spacing
        $labelKeyInstruction = New-Object System.Windows.Forms.Label -Property @{ 
            Text = "To enable GitHub integration, copy this SSH public key to your GitHub account:`n`nGitHub ? Settings ? SSH and GPG keys ? New SSH key"
            Location = New-Object System.Drawing.Point(20,60)
            Size = New-Object System.Drawing.Size(760,60)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Regular)
            ForeColor = [System.Drawing.Color]::DarkSlateGray
        }
        $formKeyDisplay.Controls.Add($labelKeyInstruction)

        # Text box with improved styling and better dimensions
        $textBoxKey = New-Object System.Windows.Forms.TextBox -Property @{ 
            Location = New-Object System.Drawing.Point(20,130)
            Size = New-Object System.Drawing.Size(760,250)
            Multiline = $true
            ScrollBars = 'Vertical'
            ReadOnly = $true
            Font = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Regular)
            Text = $publicKey
            WordWrap = $false
            BackColor = [System.Drawing.Color]::WhiteSmoke
            BorderStyle = 'Fixed3D'
        }
        $formKeyDisplay.Controls.Add($textBoxKey)

        # Automatically select all text and focus for easy copying
        $formKeyDisplay.Add_Shown({
            $textBoxKey.SelectAll()
            $textBoxKey.Focus()
        })

        # Copy button with better positioning and styling
        $buttonCopyKey = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Copy to Clipboard'
            Location = New-Object System.Drawing.Point(500,400)
            Size = New-Object System.Drawing.Size(140,35)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
            BackColor = [System.Drawing.Color]::LightGreen
            ForeColor = [System.Drawing.Color]::DarkGreen
            FlatStyle = 'Flat'
        }
        $formKeyDisplay.Controls.Add($buttonCopyKey)

        $buttonCopyKey.Add_Click({
            try {
                $publicKey | Set-Clipboard | Out-Null
                $buttonCopyKey.Text = 'Copied!'
                $buttonCopyKey.BackColor = [System.Drawing.Color]::LightBlue
                $buttonCopyKey.Enabled = $false
                
                # Re-enable button after 2 seconds with proper error handling
                $script:CopyTimer = New-Object System.Windows.Forms.Timer
                $script:CopyTimer.Interval = 2000
                $script:CopyTimer.Add_Tick({
                    try {
                        if ($buttonCopyKey -and -not $buttonCopyKey.IsDisposed) {
                            $buttonCopyKey.Text = 'Copy to Clipboard'
                            $buttonCopyKey.BackColor = [System.Drawing.Color]::LightGreen
                            $buttonCopyKey.Enabled = $true
                        }
                        if ($script:CopyTimer -and -not $script:CopyTimer.Disposed) {
                            $script:CopyTimer.Stop()
                            $script:CopyTimer.Dispose()
                            $script:CopyTimer = $null
                        }
                    } catch {
                        # Silently handle any timer cleanup errors
                        if ($script:CopyTimer) {
                            try { $script:CopyTimer.Dispose() } catch { }
                            $script:CopyTimer = $null
                        }
                    }
                })
                $script:CopyTimer.Start()
            } catch {
                [System.Windows.Forms.MessageBox]::Show('Failed to copy to clipboard. Please select all text and copy manually using Ctrl+C.', 'Copy Failed', 'OK', 'Warning') | Out-Null
            }
        })

        # Close button with better positioning and styling
        $buttonCloseKey = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Close'
            Location = New-Object System.Drawing.Point(660,400)
            Size = New-Object System.Drawing.Size(120,35)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
            BackColor = [System.Drawing.Color]::LightCoral
            ForeColor = [System.Drawing.Color]::DarkRed
            FlatStyle = 'Flat'
            DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
        $formKeyDisplay.Controls.Add($buttonCloseKey)

        $buttonCloseKey.Add_Click({
            $formKeyDisplay.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $formKeyDisplay.Close()
        })

        # Set form properties for better behavior
        $formKeyDisplay.AcceptButton = $buttonCloseKey
        $formKeyDisplay.CancelButton = $buttonCloseKey
        
        # Show the key display dialog and suppress output
        $null = $formKeyDisplay.ShowDialog()

        Write-Host ""
        Write-Host "Public Key (copy this to GitHub):"
        Write-Host "----------------------------------------"
        Write-Host $publicKey
        Write-Host "----------------------------------------"
        Write-Host ""
        Write-Host "Next Steps:"
        Write-Host "1. Go to GitHub -> Settings -> SSH and GPG keys"  
        Write-Host "2. Click 'New SSH key'"
        Write-Host "3. Paste the key above"
        Write-Host "`nNext: Add this key to GitHub -> Settings -> SSH and GPG keys -> New SSH key"
        Write-Host "================================================"
        Write-Host ""
    }
    
    # Start and configure ssh-agent
    try {
        Write-Debug-Message "[DEBUG] Starting SSH agent configuration..."
        Write-Host ""
        Write-Host "[INFO] Configuring SSH agent..." -ForegroundColor Cyan
        Write-Host ""
        
        # Start ssh-agent service if not running
        Write-Debug-Message "[DEBUG] Checking SSH agent service status..."
        $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
        
        if ($sshAgentService) {
            Write-Debug-Message "[DEBUG] SSH agent service found, status: $($sshAgentService.Status)"
        } else {
            Write-Debug-Message "[DEBUG] SSH agent service not found"
        }
        
        if ($sshAgentService.Status -ne 'Running') {
            Write-Debug-Message "[DEBUG] Starting SSH agent service..."
            Set-Service ssh-agent -StartupType Automatic
            Start-Service ssh-agent
            Write-Host ""
            Write-Host "  SSH agent service started"
            Write-Debug-Message "[DEBUG] SSH agent service started successfully"
        } else {
            Write-Debug-Message "[DEBUG] SSH agent service already running"
        }
        
        # Add key to ssh-agent
        Write-Debug-Message "[DEBUG] Adding SSH key to agent: $sshKeyPath"
        ssh-add $sshKeyPath
        Write-Host ""
        Write-Host "  SSH key added to agent"
        Write-Host ""
        Write-Debug-Message "[DEBUG] SSH key successfully added to agent"
        
    } catch {
        Write-Debug-Message "[DEBUG] SSH agent configuration failed: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "[WARNING] Could not configure SSH agent. Key may still work for GitHub." -ForegroundColor Yellow
        Write-Host ""
    }
    
}

Write-Host ""
Write-Host "================================================"
Write-Host "  STEP 3: Container Location Selection"
Write-Host "================================================"
Write-Host ""
Write-Host ""
Write-Host "Please choose your container deployment location..."
Write-Host ""

Write-Debug-Message "[DEBUG] STEP 3: Starting container location selection..."

#----------------------------------------------#
#   STEP 3: PROMPT LOCAL / REMOTE CONNECTION   #
#----------------------------------------------#

Write-Debug-Message "[DEBUG] Creating container location selection form..."

# Create a new form for local/remote selection
$formConnection = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Container Location - IMPACT NCD Germany'
    Size = New-Object System.Drawing.Size(450,240)
    Location = New-Object System.Drawing.Point(400,300)
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}
Set-FormCenterOnCurrentScreen -Form $formConnection

# Instruction rich text box with formatting
$rtbConnectionInstruction = New-Object System.Windows.Forms.RichTextBox -Property @{ 
    Location = New-Object System.Drawing.Point(20,10)
    Size = New-Object System.Drawing.Size(400,50)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
    ReadOnly = $true
    BorderStyle = 'None'
    BackColor = $formConnection.BackColor
    ScrollBars = 'None'
}

# Add formatted text
$rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$rtbConnectionInstruction.AppendText("Please choose whether you want to work locally")
$rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$rtbConnectionInstruction.AppendText(" (e.g. for testing) ")
$rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$rtbConnectionInstruction.AppendText("or remotely on the workstation")
$rtbConnectionInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$rtbConnectionInstruction.AppendText(" (e.g. running simulations for output)!")

$formConnection.Controls.Add($rtbConnectionInstruction)

# Local Container button (left-aligned)
$buttonLocal = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Local Container'
    Location = New-Object System.Drawing.Point(20,60)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formConnection.Controls.Add($buttonLocal)

# Remote Container button (left-aligned, below local button)
$buttonRemote = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Remote Container'
    Location = New-Object System.Drawing.Point(20,110)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formConnection.Controls.Add($buttonRemote)

# Remote IP address label and textbox (positioned next to remote button)
$labelRemoteIP = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Remote IP Address:'
    Location = New-Object System.Drawing.Point(160,125)
    Size = New-Object System.Drawing.Size(120,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Regular)
}
$formConnection.Controls.Add($labelRemoteIP)

$textRemoteIP = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(280,120)
    Size = New-Object System.Drawing.Size(120,20)
    Text = '10.162.194.34'
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Regular)
}
$formConnection.Controls.Add($textRemoteIP)

# Debug checkbox (positioned below remote button)
$checkBoxDebug = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'Enable Debug Mode (show detailed progress messages)'
    Location = New-Object System.Drawing.Point(20,160)
    Size = New-Object System.Drawing.Size(350,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Regular)
    Checked = $false
}
$formConnection.Controls.Add($checkBoxDebug)

# Add click handlers for the buttons
$buttonLocal.Add_Click({
    Write-Debug-Message "[DEBUG] User selected local container option"
    $script:DebugMode = $checkBoxDebug.Checked
    Write-Debug-Message "[DEBUG] Debug mode setting: $(if($script:DebugMode) { 'Enabled' } else { 'Disabled' })"
    Write-Host "[INFO] Debug mode: $(if($script:DebugMode) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "================================================"
    Write-Host "  LOCAL CONTAINER SELECTED"
    Write-Host "================================================"
    Write-Host ""
    Write-Host ""
    Write-Host "Configuring for local Docker containers..."
    Write-Host ""
    $formConnection.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $formConnection.Close()
})

#----------------------------------------------------------------#
#   STEP 4.1.1: IF REMOTE - ESTABLISH AND CHECK SSH CONNECTION   #
#----------------------------------------------------------------#

$buttonRemote.Add_Click({
    Write-Debug-Message "[DEBUG] User selected remote container option"
    $script:DebugMode = $checkBoxDebug.Checked
    Write-Debug-Message "[DEBUG] Debug mode setting: $(if($script:DebugMode) { 'Enabled' } else { 'Disabled' })"
    Write-Host "[INFO] Debug mode: $(if($script:DebugMode) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "================================================"
    Write-Host "  REMOTE CONTAINER SELECTED"
    Write-Host "================================================"
    Write-Host ""
    Write-Host ""
    Write-Host "Configuring for remote Docker containers..."
    Write-Host ""
    Write-Host ""
    Write-Host "[INFO] Testing SSH connection to remote workstation..." -ForegroundColor Cyan
    Write-Host ""
    
    Write-Debug-Message "[DEBUG] STEP 4.1.1: Starting SSH connection establishment and testing..."
    
    # Get user-provided IP address and validate it
    $userProvidedIP = $textRemoteIP.Text.Trim()
    Write-Debug-Message "[DEBUG] User-provided IP address: $userProvidedIP"
    
    # Basic IP validation
    if ([string]::IsNullOrWhiteSpace($userProvidedIP)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a valid IP address for the remote host.', 'Invalid IP Address', 'OK', 'Error')
        return
    }
    
    # Simple IP format validation (basic check)
    if ($userProvidedIP -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        [System.Windows.Forms.MessageBox]::Show('Please enter a valid IP address format (e.g., 192.168.1.100).', 'Invalid IP Format', 'OK', 'Error')
        return
    }
    
    Write-Host "  Using remote IP address: $userProvidedIP" -ForegroundColor Cyan
    
    # Define remote host using user-provided IP (update this IP address to match your workstation)
    $remoteHost = "php-workstation@$userProvidedIP"  #TODO: Implement individual users!
    Write-Debug-Message "[DEBUG] Target remote host: $remoteHost"
 
    # Test SSH connection with detailed feedback
    try {
        Write-Host ""
        Write-Host "  Attempting connection to: $remoteHost"
        Write-Host ""
        
        # First, try SSH key authentication (no password needed)
        Write-Host ""
        Write-Host "  [INFO] Testing SSH key authentication..." -ForegroundColor Cyan
        Write-Host ""
        
        # Use specific SSH key to avoid "Too many authentication failures"
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        Write-Debug-Message "[DEBUG] Using SSH key for authentication: $sshKeyPath"

        # Validate that SSH key exists before attempting to use it
        Write-Debug-Message "[DEBUG] Validating SSH key existence..."
        if (-not (Test-Path $sshKeyPath)) {
            Write-Debug-Message "[DEBUG] SSH key validation failed - file not found"
            Write-Host ""
            Write-Host "  [ERROR] SSH key not found: $sshKeyPath" -ForegroundColor Red
            Write-Host "  Please ensure SSH key generation completed successfully" -ForegroundColor Red
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("SSH key not found at: $sshKeyPath`n`nPlease restart the application to regenerate SSH keys.", "SSH Key Missing", "OK", "Error")
            return
        }
        
        Write-Host "  Using SSH key: $sshKeyPath" -ForegroundColor Cyan
        
        Write-Debug-Message "[DEBUG] Starting SSH connection test with timeout..."
        
        # Use PowerShell job with timeout for SSH connection test
        $sshTestJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost)
            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'SSH connection successful'" 2>&1
            return @{
                Output = $result
                ExitCode = $LASTEXITCODE
            }
        } -ArgumentList $sshKeyPath, $remoteHost
        
        Write-Debug-Message "[DEBUG] SSH test job started, waiting for completion (15s timeout)..."
        
        if (Wait-Job $sshTestJob -Timeout 15) {
            Write-Debug-Message "[DEBUG] SSH test job completed within timeout"
            $jobResult = Receive-Job $sshTestJob
            Remove-Job $sshTestJob
            $sshTestResult = $jobResult.Output
            $SSHEXITCODE = $jobResult.ExitCode
            Write-Debug-Message "[DEBUG] SSH test result: Exit code $SSHEXITCODE, Output: '$sshTestResult'"
        } else {
            Write-Debug-Message "[DEBUG] SSH test job timed out, forcing cleanup"
            Remove-Job $sshTestJob -Force
            $sshTestResult = "SSH connection test timed out after 15 seconds"
            $SSHEXITCODE = 1
        }

        if ($SSHEXITCODE -eq 0 -and $sshTestResult -match "SSH connection successful" -and $sshTestResult -notmatch "Permission denied") {
            Write-Debug-Message "[DEBUG] SSH key authentication successful"
            Write-Host ""
            Write-Host "  [SUCCESS] SSH key authentication successful!" -ForegroundColor Green
            Write-Host "  Response: $sshTestResult"
            Write-Host "  Remote workstation is reachable"
            Write-Host ""

            # Extract IP address from remote host string
            $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
            $script:RemoteHostIp = $remoteIP
            
        } else {
            Write-Debug-Message "[DEBUG] SSH key authentication failed, password authentication required"
            Write-Debug-Message "[DEBUG] SSH test details - Exit code: $SSHEXITCODE, Output: '$sshTestResult'"
            Write-Host ""
            Write-Host "  [INFO] SSH key authentication failed - password authentication required" -ForegroundColor Cyan
            Write-Host "  Response: $sshTestResult"
            Write-Host "  This is normal for first-time connections"
            Write-Host ""
            
            # Prompt user for remote host password #TODO: Change based on individual users!
            Write-Debug-Message "[DEBUG] Creating password input form for remote host authentication"
            $formPassword = New-Object System.Windows.Forms.Form -Property @{ 
                Text = 'Remote Host Password - IMPACT NCD Germany'
                Size = New-Object System.Drawing.Size(450,180)
                FormBorderStyle = 'FixedDialog'
                MaximizeBox = $false
            }
            Set-FormCenterOnCurrentScreen -Form $formPassword

            # Instruction label
            $labelPasswordInstruction = New-Object System.Windows.Forms.Label -Property @{ 
                Text = "Please enter the password for the remote workstation:`n$remoteHost"
                Location = New-Object System.Drawing.Point(10,10)
                Size = New-Object System.Drawing.Size(420,40)
                Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
                TextAlign = 'MiddleCenter'
            }
            $formPassword.Controls.Add($labelPasswordInstruction)

            # Password textbox
            $textRemotePassword = New-Object System.Windows.Forms.TextBox -Property @{ 
                Location = New-Object System.Drawing.Point(50,60)
                Size = New-Object System.Drawing.Size(340,20)
                UseSystemPasswordChar = $true
                Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
            }
            $formPassword.Controls.Add($textRemotePassword)

            # OK and Cancel buttons
            $buttonPasswordOK = New-Object System.Windows.Forms.Button -Property @{
                Text = 'Connect'
                Location = New-Object System.Drawing.Point(250,100)
                Size = New-Object System.Drawing.Size(75,30)
                Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
            }
            $formPassword.Controls.Add($buttonPasswordOK)

            $buttonPasswordCancel = New-Object System.Windows.Forms.Button -Property @{
                Text = 'Cancel'
                Location = New-Object System.Drawing.Point(340,100)
                Size = New-Object System.Drawing.Size(75,30)
                DialogResult = [System.Windows.Forms.DialogResult]::Cancel
            }
            $formPassword.Controls.Add($buttonPasswordCancel)

            # Set default buttons
            $formPassword.AcceptButton = $buttonPasswordOK
            $formPassword.CancelButton = $buttonPasswordCancel

            # Add validation for password OK button click
            $buttonPasswordOK.Add_Click({
                if ([string]::IsNullOrWhiteSpace($textRemotePassword.Text)) { #TODO: Change based on individual users!
                    [System.Windows.Forms.MessageBox]::Show('Please enter the remote host password.', 'Password Required', 'OK', 'Warning')
                    $textRemotePassword.Focus()
                    return
                }
                $formPassword.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $formPassword.Close()
            })

            # Focus on password field
            $textRemotePassword.Select()

            # Show the password dialog
            Write-Debug-Message "[DEBUG] Displaying password input dialog to user"
            $passwordResult = $formPassword.ShowDialog()
            Write-Debug-Message "[DEBUG] Password dialog result: $passwordResult"
            
            if ($passwordResult -eq [System.Windows.Forms.DialogResult]::OK) {
                Write-Debug-Message "[DEBUG] Password provided by user, processing credentials..."
                # Secure password handling: Convert to SecureString immediately
                Write-Debug-Message "[DEBUG] Converting password to secure string for safe handling"
                Write-Host ""
                Write-Host "  [INFO] Password provided, securing credentials..." -ForegroundColor Cyan
                Write-Host ""
                $securePassword = ConvertTo-SecureString $textRemotePassword.Text -AsPlainText -Force
                                
                # Create credential object for secure handling
                $hostParts = $remoteHost -split "@"
                Write-Debug-Message "[DEBUG] Parsing remote host string: $remoteHost"
                if ($hostParts.Count -eq 2) {
                    $sshUser = $hostParts[0]
                    $sshHost = $hostParts[1]
                    Write-Debug-Message "[DEBUG] Parsed SSH user: $sshUser, SSH host: $sshHost"
                } else {
                    $sshUser = $env:USERNAME
                    $sshHost = $remoteHost
                    Write-Debug-Message "[DEBUG] Using default user: $sshUser, host: $sshHost"
                }
                
                $remoteCredential = New-Object System.Management.Automation.PSCredential($sshUser, $securePassword)
                
                Write-Debug-Message "[DEBUG] Credential object created, clearing password from form"
                
                # Clear the plain text password from the textbox and form
                $textRemotePassword.Text = ""
                $textRemotePassword.Clear()
                
                # Dispose of the password form securely
                $formPassword.Dispose()
                Write-Debug-Message "[DEBUG] Password form disposed securely"
                
                Write-Host ""
                Write-Host "  [INFO] Credentials secured, testing connection..." -ForegroundColor Cyan
                Write-Host ""
                
                # Skip connection testing and proceed directly to SSH key copying
                try {
                    Write-Host ""
                    Write-Host "  [INFO] Setting up SSH key for passwordless authentication..." -ForegroundColor Cyan
                    Write-Host "  This will allow future connections without password prompts"
                    Write-Host ""
                    
                    # Get the public key content
                    $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME.pub"
                    if (Test-Path $sshPublicKeyPath) {
                        $publicKeyContent = Get-Content $sshPublicKeyPath -Raw
                        $publicKeyContent = $publicKeyContent.Trim()
                        
                        Write-Host ""
                        Write-Host "  Copying SSH key to remote host..."
                        Write-Host ""
                        
                        $keyCopySuccess = $false
                        
                        # Method 1: Try using Posh-SSH (PowerShell SSH module) first
                        try {
                            # Check if Posh-SSH module is available AND functional in current PowerShell version
                            $poshSSHModule = Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue
                            $poshSSHFunctional = $false
                            
                            if ($poshSSHModule) {
                                # Test if the module can be imported and has required cmdlets
                                try {
                                    Import-Module Posh-SSH -Force -ErrorAction Stop
                                    
                                    # Verify that required cmdlets are available
                                    $requiredCmdlets = @('New-SSHSession', 'Invoke-SSHCommand', 'Remove-SSHSession')
                                    $missingCmdlets = @()
                                    
                                    foreach ($cmdlet in $requiredCmdlets) {
                                        if (-not (Get-Command $cmdlet -ErrorAction SilentlyContinue)) {
                                            $missingCmdlets += $cmdlet
                                        }
                                    }
                                    
                                    if ($missingCmdlets.Count -eq 0) {
                                        $poshSSHFunctional = $true
                                        Write-Host "  [SUCCESS] Posh-SSH module found and functional" -ForegroundColor Green
                                    } else {
                                        Write-Host "  [WARNING] Posh-SSH module found but missing cmdlets: $($missingCmdlets -join ', ')" -ForegroundColor Yellow
                                        Write-Host "  This usually means it's installed for a different PowerShell version" -ForegroundColor Yellow
                                    }
                                } catch {
                                    Write-Host "  [WARNING] Posh-SSH module found but failed to import: $($_.Exception.Message)" -ForegroundColor Yellow
                                }
                            }
                            
                            if (-not $poshSSHFunctional) {
                                Write-Host "  Posh-SSH module not functional for current PowerShell version, installing..." -ForegroundColor Cyan
                                Write-Host "  PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Cyan
                                Write-Host "  Module Path: $($env:PSModulePath -split ';' | Select-Object -First 1)" -ForegroundColor Cyan
                                
                                try {
                                    # Ensure PowerShell Gallery is trusted and available
                                    $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
                                    if (-not $psGallery -or $psGallery.InstallationPolicy -ne 'Trusted') {
                                        Write-Host "  Setting PowerShell Gallery as trusted repository..." -ForegroundColor Cyan
                                        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                                    }
                                    
                                    # For PowerShell 7, install to CurrentUser scope to ensure it goes to the right location
                                    $installScope = if ($PSVersionTable.PSVersion.Major -ge 6) { 'CurrentUser' } else { 'AllUsers' }
                                    Write-Host "  Installing to scope: $installScope" -ForegroundColor Cyan
                                    
                                    # Install Posh-SSH module
                                    Write-Host "  Downloading and installing Posh-SSH module..." -ForegroundColor Cyan
                                    Install-Module -Name Posh-SSH -Force -AllowClobber -Scope $installScope -ErrorAction Stop
                                    
                                    Write-Host "  [SUCCESS] Posh-SSH module installed successfully!" -ForegroundColor Green
                                    
                                    # Force module refresh and re-import
                                    Write-Host "  Refreshing module cache and re-importing..." -ForegroundColor Cyan
                                    
                                    # Remove any existing module from current session
                                    Get-Module Posh-SSH -ErrorAction SilentlyContinue | Remove-Module -Force
                                    
                                    # Clear module cache and force refresh
                                    if (Get-Command Import-Module -ParameterName -Force -ErrorAction SilentlyContinue) {
                                        Import-Module Posh-SSH -Force -Global -ErrorAction Stop
                                    } else {
                                        Import-Module Posh-SSH -Force -ErrorAction Stop
                                    }
                                    
                                    # Re-check if module is now available and functional
                                    $poshSSHModule = Get-Module -ListAvailable -Name Posh-SSH -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
                                    
                                    if ($poshSSHModule) {
                                        Write-Host "  [INFO] Posh-SSH version: $($poshSSHModule.Version)" -ForegroundColor Cyan
                                        Write-Host "  [INFO] Installed at: $($poshSSHModule.ModuleBase)" -ForegroundColor Cyan
                                        Write-Host "  [INFO] Module loaded from: $((Get-Module Posh-SSH).ModuleBase)" -ForegroundColor Cyan
                                        
                                        # Wait a moment for module to fully load
                                        Start-Sleep -Milliseconds 500
                                        
                                        # Re-verify cmdlets are now available with more detailed checking
                                        $requiredCmdlets = @('New-SSHSession', 'Invoke-SSHCommand', 'Remove-SSHSession')
                                        $missingCmdlets = @()
                                        $availableCmdlets = @()
                                        
                                        foreach ($cmdlet in $requiredCmdlets) {
                                            $cmd = Get-Command $cmdlet -ErrorAction SilentlyContinue
                                            if ($cmd) {
                                                $availableCmdlets += "$cmdlet (from $($cmd.ModuleName))"
                                            } else {
                                                $missingCmdlets += $cmdlet
                                            }
                                        }
                                        
                                        Write-Host "  [INFO] Available cmdlets: $($availableCmdlets -join ', ')" -ForegroundColor Cyan
                                        
                                        if ($missingCmdlets.Count -eq 0) {
                                            $poshSSHFunctional = $true
                                            Write-Host "  [SUCCESS] All required cmdlets now available" -ForegroundColor Green
                                        } else {
                                            # Try one more time with explicit module specification
                                            Write-Host "  [WARNING] Still missing cmdlets, trying alternative import method..." -ForegroundColor Yellow
                                            
                                            try {
                                                # Try importing specific cmdlets
                                                Import-Module Posh-SSH -Function $requiredCmdlets -Force -ErrorAction Stop
                                                
                                                # Check again
                                                $missingCmdlets = @()
                                                foreach ($cmdlet in $requiredCmdlets) {
                                                    if (-not (Get-Command $cmdlet -ErrorAction SilentlyContinue)) {
                                                        $missingCmdlets += $cmdlet
                                                    }
                                                }
                                                
                                                if ($missingCmdlets.Count -eq 0) {
                                                    $poshSSHFunctional = $true
                                                    Write-Host "  [SUCCESS] All required cmdlets now available via explicit import" -ForegroundColor Green
                                                } else {
                                                    throw "Still missing required cmdlets after explicit import: $($missingCmdlets -join ', ')"
                                                }
                                            } catch {
                                                Write-Host "  [WARNING] Alternative import failed: $($_.Exception.Message)" -ForegroundColor Yellow
                                                throw "Missing required cmdlets after installation: $($missingCmdlets -join ', '). This may indicate a corrupted installation or PowerShell module path issue."
                                            }
                                        }
                                    } else {
                                        throw "Module installation appeared successful but module is still not available"
                                    }
                                } catch {
                                    Write-Host "  [WARNING] Failed to install functional Posh-SSH: $($_.Exception.Message)" -ForegroundColor Yellow
                                    Write-Host "  Falling back to plink method..." -ForegroundColor Cyan
                                    $poshSSHFunctional = $false
                                }
                            }
                            
                            if ($poshSSHFunctional) {
                                Write-Host "  Using Posh-SSH PowerShell module for key copying..." -ForegroundColor Cyan
                                
                                # Create SSH session for command execution
                                Write-Host "  Testing Posh-SSH connection with functional verification..." -ForegroundColor Cyan
                                Write-Host "  Connecting to: $sshHost as $sshUser" -ForegroundColor Cyan
                                
                                try {
                                    # Quick functional test: create session and immediately test with a simple command
                                    Write-Host "  Creating SSH session with quick timeout..." -ForegroundColor Cyan
                                    
                                    # Create SSH session with shorter timeout
                                    $sshSession = New-SSHSession -ComputerName $sshHost -Credential $remoteCredential -AcceptKey -ConnectionTimeout 15 -ErrorAction Stop
                                    
                                    if (-not $sshSession) {
                                        throw "SSH session creation returned null"
                                    }
                                    
                                    $sessionId = $sshSession.SessionId
                                    Write-Host "  Session ID: $sessionId, Testing functionality..." -ForegroundColor Cyan
                                    
                                    # Immediately test if the session actually works with a simple command
                                    # This is much more reliable than checking connection status
                                    $testCommand = Invoke-SSHCommand -SessionId $sessionId -Command "echo 'POSH_SSH_TEST_OK'" -TimeOut 10 -ErrorAction Stop
                                    
                                    if ($testCommand.Output -match "POSH_SSH_TEST_OK" -and $testCommand.ExitStatus -eq 0) {
                                        Write-Host "  [SUCCESS] Posh-SSH functional test passed!" -ForegroundColor Green
                                        Write-Host "  Response: $($testCommand.Output.Trim())" -ForegroundColor Green
                                        
                                        # Session is working, continue with key installation logic here...
                                        Write-Host "  SSH session is functional, proceeding with key installation..." -ForegroundColor Cyan
                                        
                                    } else {
                                        throw "Posh-SSH session created but test command failed. Output: '$($testCommand.Output)', Exit: $($testCommand.ExitStatus)"
                                    }
                                    
                                } catch {
                                    # Clean up any sessions that were created
                                    try {
                                        if ($sessionId) { Remove-SSHSession -SessionId $sessionId -ErrorAction SilentlyContinue | Out-Null }
                                    } catch { }
                                    
                                    Write-Host "  [WARNING] Posh-SSH connection test failed: $($_.Exception.Message)" -ForegroundColor Yellow
                                    Write-Host "  This is normal - falling back to plink method..." -ForegroundColor Cyan
                                    throw "Posh-SSH failed: $($_.Exception.Message)"
                                }
                                
                                try {
                                    # Create temporary file for public key
                                    $tempKeyFile = "$env:TEMP\ps_key_tmp.pub"
                                    Set-Content -Path $tempKeyFile -Value $publicKeyContent -NoNewline -Encoding ASCII
                                    
                                    # Verify the temp file exists and has content
                                    if (-not (Test-Path $tempKeyFile)) {
                                        throw "Temporary key file was not created successfully"
                                    }
                                    
                                    $fileSize = (Get-Item $tempKeyFile).Length
                                    if ($fileSize -eq 0) {
                                        throw "Temporary key file is empty"
                                    }
                                    
                                    Write-Host "  Key file size: $fileSize bytes" -ForegroundColor Cyan
                                    
                                    # Use simple filename in /tmp (most reliable location)
                                    $uniqueFileName = "ssh_key_temp_$(Get-Date -Format 'HHmmss').pub"
                                    $remoteTemp = "/tmp/$uniqueFileName"
                                    
                                    Write-Host "  Creating key file on remote host via SSH command..." -ForegroundColor Cyan
                                    
                                    # Create the file directly via SSH command (more reliable than SFTP)
                                    $keyContent = Get-Content $tempKeyFile -Raw
                                    $keyContent = $keyContent.Trim() -replace "'", "'\''"  # Escape single quotes
                                    
                                    Write-Debug-Message "  [DEBUG] Key content length: $($keyContent.Length) characters"
                                    Write-Debug-Message "  [DEBUG] Remote destination: $remoteTemp"
                                    
                                    $createFileCommand = "echo '$keyContent' > $remoteTemp && echo 'FILE_CREATED' && ls -la $remoteTemp"
                                    Write-Debug-Message "  [DEBUG] Executing SSH command..."
                                    
                                    $createResult = Invoke-SSHCommand -SessionId $sessionId -Command $createFileCommand -ErrorAction Stop
                                    
                                    Write-Debug-Message "  [DEBUG] SSH command exit status: $($createResult.ExitStatus)"
                                    Write-Debug-Message "  [DEBUG] SSH command output: '$($createResult.Output)'"
                                    
                                    if ($createResult.Output -match "FILE_CREATED") {
                                        Write-Host "  [SUCCESS] Key file created via SSH command" -ForegroundColor Green
                                    } else {
                                        throw "SSH file creation failed: $($createResult.Output)"
                                    }
                                    
                                    Write-Debug-Message "  [DEBUG] File upload successful, proceeding with key validation on remote..."
                                    
                                    # Compose remote script to install the key properly
                                    Write-Debug-Message "  [DEBUG] Preparing remote installation script..."
                                    Write-Debug-Message "  [DEBUG] Using USERNAME from script: $USERNAME"
                                    
                                    # Create the script with proper line endings and variable substitution
                                    $remoteScriptContent = @"
set -eu
umask 077
echo "SCRIPT_START"

# Get actual user info
ACTUAL_USER=`$(whoami)
HOME_DIR=`$(eval echo ~`$ACTUAL_USER)
USER_SSH_DIR="`$HOME_DIR/.ssh"
AUTH_KEYS="`$USER_SSH_DIR/authorized_keys"
KEY_TARGET_PUB="`$USER_SSH_DIR/id_ed25519_$USERNAME.pub"

echo "ACTUAL_USER: `$ACTUAL_USER"
echo "HOME_DIR: `$HOME_DIR"
echo "USER_SSH_DIR: `$USER_SSH_DIR"
echo "AUTH_KEYS: `$AUTH_KEYS"
echo "KEY_TARGET_PUB: `$KEY_TARGET_PUB"

# Ensure home directory exists
if [ ! -d "`$HOME_DIR" ]; then
  echo "Creating home directory: `$HOME_DIR"
  mkdir -p "`$HOME_DIR"
  chown `$ACTUAL_USER:`$ACTUAL_USER "`$HOME_DIR"
  chmod 755 "`$HOME_DIR"
  echo "Home directory created"
else
  echo "Home directory exists: `$HOME_DIR"
fi

# Create .ssh directory if it doesn't exist
if [ ! -d "`$USER_SSH_DIR" ]; then
  echo "Creating SSH directory: `$USER_SSH_DIR"
  mkdir -p "`$USER_SSH_DIR"
  chown `$ACTUAL_USER:`$ACTUAL_USER "`$USER_SSH_DIR"
  chmod 700 "`$USER_SSH_DIR"
  echo "SSH directory created and permissions set"
else
  echo "SSH directory already exists: `$USER_SSH_DIR"
fi

# Create authorized_keys file if it doesn't exist
if [ ! -f "`$AUTH_KEYS" ]; then
  echo "Creating authorized_keys file: `$AUTH_KEYS"
  touch "`$AUTH_KEYS"
  chown `$ACTUAL_USER:`$ACTUAL_USER "`$AUTH_KEYS"
  chmod 600 "`$AUTH_KEYS"
  echo "authorized_keys file created and permissions set"
else
  echo "authorized_keys file already exists: `$AUTH_KEYS"
fi

# Check if temp file exists
if [ ! -f "$remoteTemp" ]; then
  echo "ERROR: Temp file does not exist: $remoteTemp"
  exit 1
else
  echo "Temp file found: $remoteTemp"
  echo "Temp file size: `$(wc -c < $remoteTemp) bytes"
fi

# Copy the public key file to the SSH directory (optional - for reference)
echo "Copying public key file to: `$KEY_TARGET_PUB"
cp "$remoteTemp" "`$KEY_TARGET_PUB"
chown `$ACTUAL_USER:`$ACTUAL_USER "`$KEY_TARGET_PUB"
chmod 644 "`$KEY_TARGET_PUB"
echo "Public key file copied and permissions set"

# Read the key content for authorized_keys
echo "Reading key content from copied file..."
NEW_KEY=`$(cat "`$KEY_TARGET_PUB")
echo "Key content length: `${#NEW_KEY} characters"
echo "Key content preview: `${NEW_KEY:0:50}..."

# Only append if not already present (exact match check)
echo "Checking if key already exists in authorized_keys..."
if ! grep -qxF "`$NEW_KEY" "`$AUTH_KEYS"; then
  echo "Key not found in authorized_keys, adding it..."
  echo "`$NEW_KEY" >> "`$AUTH_KEYS"
  echo "KEY_ADDED"
else
  echo "Key already exists in authorized_keys"
  echo "KEY_ALREADY_EXISTS"
fi

# Ensure correct permissions on all files
echo "Setting correct permissions..."
chmod 755 "`$HOME_DIR"
chmod 700 "`$USER_SSH_DIR"
chmod 600 "`$AUTH_KEYS"
chmod 644 "`$KEY_TARGET_PUB"
echo "Permissions updated"

# Fix ownership to ensure everything belongs to the user
echo "Fixing ownership..."
chown `$ACTUAL_USER:`$ACTUAL_USER "`$HOME_DIR"
chown -R `$ACTUAL_USER:`$ACTUAL_USER "`$USER_SSH_DIR"
echo "Ownership fixed"

# Fix SELinux context if available
if command -v restorecon >/dev/null 2>&1; then
  echo "Fixing SELinux context..."
  restorecon -Rv "`$USER_SSH_DIR" || true
  echo "SELinux context fixed"
else
  echo "SELinux not available, skipping context fix"
fi

echo "Cleaning up temp file..."
rm -f "$remoteTemp"
echo "Temp file removed"

echo "SSH_KEY_COPIED"
echo "SCRIPT_END"
"@

                                    # Convert Windows line endings to Unix line endings
                                    $remoteScript = $remoteScriptContent -replace "`r`n", "`n" -replace "`r", "`n"
                                    
                                    Write-Debug-Message "  [DEBUG] Executing remote installation script..."
                                    Write-Debug-Message "  [DEBUG] Script length: $($remoteScript.Length) characters"
                                    Write-Debug-Message "  [DEBUG] Session ID: $sessionId"
                                    
                                    # Execute the remote script
                                    $scriptResult = Invoke-SSHCommand -SessionId $sessionId -Command $remoteScript -ErrorAction Stop
                                    
                                    Write-Debug-Message "  [DEBUG] Remote script execution completed"
                                    Write-Debug-Message "  [DEBUG] Remote script exit status: $($scriptResult.ExitStatus)"
                                    Write-Debug-Message "  [DEBUG] Output length: $($scriptResult.Output.Length) characters"
                                    Write-Debug-Message "  [DEBUG] Error length: $($scriptResult.Error.Length) characters"
                                    Write-Debug-Message "  [DEBUG] Remote script output:"
                                    Write-Debug-Message "  [DEBUG] ==================="
                                    if ($scriptResult.Output) {
                                        Write-Debug-Message "$($scriptResult.Output)"
                                    } else {
                                        Write-Debug-Message "  [DEBUG] NO OUTPUT RECEIVED"
                                    }
                                    Write-Debug-Message "  [DEBUG] ==================="
                                    if ($scriptResult.Error) {
                                        Write-Debug-Message "  [DEBUG] Remote script errors:"
                                        Write-Debug-Message "  [DEBUG] ==================="
                                        Write-Debug-Message "$($scriptResult.Error)"
                                        Write-Debug-Message "  [DEBUG] ==================="
                                    }
                                    
                                    if ($scriptResult.Output -match "SSH_KEY_COPIED") {
                                        if ($scriptResult.Output -match "KEY_ALREADY_EXISTS") {
                                            Write-Host "  [INFO] SSH key already exists in authorized_keys (Posh-SSH)" -ForegroundColor Cyan
                                        } else {
                                            Write-Host "  [SUCCESS] SSH key copied using Posh-SSH!" -ForegroundColor Green
                                        }
                                        $keyCopySuccess = $true
                                    } else {
                                        Write-Host "  [WARNING] Posh-SSH key copy may have failed: $($scriptResult.Output)" -ForegroundColor Yellow
                                        Write-Debug-Message "  [DEBUG] Expected 'SSH_KEY_COPIED' marker not found in output"
                                    }
                                    
                                } finally {
                                    # Clean up temp file and sessions
                                    if (Test-Path $tempKeyFile) { Remove-Item $tempKeyFile -Force -ErrorAction SilentlyContinue }
                                    if ($sessionId) { Remove-SSHSession -SessionId $sessionId | Out-Null }
                                }
                                
                            } else {
                                Write-Host "  Posh-SSH module not available, trying plink..." -ForegroundColor Yellow
                            }
                        } catch {
                            Write-Host "  [WARNING] Posh-SSH method failed: $($_.Exception.Message)" -ForegroundColor Yellow
                            Write-Host "  Trying plink as fallback..." -ForegroundColor Cyan
                        }
                        
                        # Method 2: Fallback to plink if Posh-SSH failed or unavailable
                        if (-not $keyCopySuccess) {
                            $plinkPath = Get-Command plink.exe -ErrorAction SilentlyContinue
                            if ($plinkPath) {
                                Write-Host "  Using PuTTY plink as fallback for key copying..." -ForegroundColor Cyan
                                
                                # First check if key already exists to avoid duplicates
                                $checkCommand = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && if grep -qxF '$publicKeyContent' ~/.ssh/authorized_keys; then echo 'KEY_EXISTS'; else echo 'KEY_NOT_FOUND'; fi"
                                
                                # Convert secure password to plain text only when needed
                                $plainPassword = $remoteCredential.GetNetworkCredential().Password
                                $checkResult = & plink.exe -ssh -batch -pw $plainPassword -l $sshUser $sshHost $checkCommand 2>&1
                                
                                if ($checkResult -match "KEY_EXISTS") {
                                    Write-Host "  [INFO] SSH key already exists in authorized_keys (plink)" -ForegroundColor Cyan
                                    $keyCopySuccess = $true
                                } elseif ($checkResult -match "KEY_NOT_FOUND") {
                                    # Key doesn't exist, so add it
                                    $keyCommand = "echo '$publicKeyContent' >> ~/.ssh/authorized_keys && echo SSH_KEY_COPIED"
                                    $keyCopyResult = & plink.exe -ssh -batch -pw $plainPassword -l $sshUser $sshHost $keyCommand 2>&1
                                    
                                    if ($keyCopyResult -match "SSH_KEY_COPIED") {
                                        Write-Host "  [SUCCESS] SSH key copied using plink!" -ForegroundColor Green
                                        $keyCopySuccess = $true
                                    } else {
                                        Write-Host "  [ERROR] plink key copy failed: $keyCopyResult" -ForegroundColor Red
                                    }
                                } else {
                                    Write-Host "  [ERROR] plink key existence check failed: $checkResult" -ForegroundColor Red
                                }
                                
                                # Clear the plain text password from memory immediately
                                $plainPassword = $null
                                [System.GC]::Collect()
                            } else {
                                Write-Host "  [ERROR] Neither Posh-SSH nor plink available for key copying" -ForegroundColor Red
                                Write-Host "  Please install either:" -ForegroundColor Yellow
                                Write-Host "  - Posh-SSH module: Install-Module Posh-SSH -Scope CurrentUser" -ForegroundColor Yellow
                                Write-Host "  - PuTTY (plink.exe) from https://www.putty.org/" -ForegroundColor Yellow
                            }
                        }
                        
                        if ($keyCopySuccess) {
                            # Success message and optional cleanup
                            Write-Host ""
                            Write-Host "  [SUCCESS] SSH key successfully set up on remote host!" -ForegroundColor Green
                            Write-Host "  Future connections will not require password"
                            Write-Host ""
                            
                            # Only run cleanup if we used plink and actually added a new key (not if key already existed)
                            if ($plinkPath -and -not $poshSSHModule -and $keyCopyResult -match "SSH_KEY_COPIED") {
                                Write-Host "  [INFO] Running additional cleanup for plink method..." -ForegroundColor Cyan
                                $cleanupCommand = "sort ~/.ssh/authorized_keys | uniq > ~/.ssh/authorized_keys.tmp && mv ~/.ssh/authorized_keys.tmp ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
                                $plainPassword = $remoteCredential.GetNetworkCredential().Password
                                & plink.exe -ssh -batch -pw $plainPassword -l $sshUser $sshHost $cleanupCommand 2>&1 | Out-Null
                                $plainPassword = $null
                                [System.GC]::Collect()
                                Write-Host "  [INFO] Cleanup completed" -ForegroundColor Cyan
                            } else {
                                Write-Host "  [INFO] No additional cleanup needed" -ForegroundColor Cyan
                            }
                                
                                # Test passwordless connection with retry logic
                                Write-Host "  [INFO] Testing passwordless SSH connection..." -ForegroundColor Cyan
                                Write-Host "  (Waiting for remote SSH service to update authorized_keys...)" -ForegroundColor Cyan
                                Start-Sleep -Seconds 3  # Give the remote system more time to process the key
                                
                                # Try passwordless connection with multiple attempts
                                $maxRetries = 3
                                $finalTestSuccess = $false
                                $finalTest = ""
                                
                                for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
                                    Write-Host "  Attempt $attempt of $maxRetries..." -ForegroundColor Cyan
                                    
                                    # Use PowerShell job with timeout for passwordless test
                                    $passwordlessTestJob = Start-Job -ScriptBlock {
                                        param($sshKeyPath, $remoteHost)
                                        $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes $remoteHost "echo 'Passwordless SSH successful'" 2>&1
                                        return @{
                                            Output = $result
                                            ExitCode = $LASTEXITCODE
                                        }
                                    } -ArgumentList $sshKeyPath, $remoteHost
                                    
                                    if (Wait-Job $passwordlessTestJob -Timeout 15) {
                                        $jobResult = Receive-Job $passwordlessTestJob
                                        Remove-Job $passwordlessTestJob
                                        $finalTest = $jobResult.Output
                                        $passwordlessExitCode = $jobResult.ExitCode
                                    } else {
                                        Remove-Job $passwordlessTestJob -Force
                                        $finalTest = "Passwordless SSH test timed out after 15 seconds"
                                        $passwordlessExitCode = 1
                                    }
                                    
                                    if ($passwordlessExitCode -eq 0 -and $finalTest -match "Passwordless SSH successful" -and $finalTest -notmatch "Permission denied") {
                                        $finalTestSuccess = $true
                                        break
                                    } else {
                                        Write-Host "    Attempt $attempt failed: $finalTest" -ForegroundColor Yellow
                                        if ($attempt -lt $maxRetries) {
                                            Write-Host "    Retrying in 2 seconds..." -ForegroundColor Cyan
                                            Start-Sleep -Seconds 2
                                        }
                                    }
                                }
                                
                                if ($finalTestSuccess) {
                                    Write-Host ""
                                    Write-Host "  [SUCCESS] Passwordless SSH authentication confirmed!" -ForegroundColor Green
                                    Write-Host "  Response: $finalTest"
                                    Write-Host ""
                                    
                                    # Now copy the private key and known_hosts files for Docker container mounting
                                    Write-Host "  [INFO] Copying SSH private key and known_hosts files for Docker mounting..." -ForegroundColor Cyan
                                    
                                    # Copy private key file
                                    $sshPrivateKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                                    $sshKnownHostsPath = "$HOME\.ssh\known_hosts"
                                    
                                    if (Test-Path $sshPrivateKeyPath) {
                                        # First, ensure the remote .ssh directory exists with correct permissions
                                        $setupRemoteSSHCommand = "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
                                        $setupRemoteSSHJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $setupRemoteSSHCommand
                                        
                                        if (Wait-Job $setupRemoteSSHJob -Timeout 15) {
                                            Receive-Job $setupRemoteSSHJob | Out-Null
                                            Remove-Job $setupRemoteSSHJob
                                        } else {
                                            Remove-Job $setupRemoteSSHJob -Force
                                            Write-Host "    [WARNING] Remote SSH directory setup timed out after 15 seconds" -ForegroundColor Yellow
                                        }
                                        
                                        # Read private key content and encode in base64 to avoid shell escaping issues
                                        $privateKeyContent = Get-Content $sshPrivateKeyPath -Raw
                                        $privateKeyBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($privateKeyContent))
                                        
                                        # Remove any existing file/directory that might be in the way
                                        $cleanupPrivateKeyCommand = "rm -rf ~/.ssh/id_ed25519_${USERNAME}"
                                        $cleanupPrivateKeyJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $cleanupPrivateKeyCommand
                                        
                                        if (Wait-Job $cleanupPrivateKeyJob -Timeout 15) {
                                            Receive-Job $cleanupPrivateKeyJob | Out-Null
                                            Remove-Job $cleanupPrivateKeyJob
                                        } else {
                                            Remove-Job $cleanupPrivateKeyJob -Force
                                            Write-Host "    [WARNING] Private key cleanup timed out after 15 seconds" -ForegroundColor Yellow
                                        }
                                        
                                        # Copy private key to remote system
                                        $copyPrivateKeyCommand = "echo '$privateKeyBase64' | base64 -d > ~/.ssh/id_ed25519_${USERNAME} && chmod 600 ~/.ssh/id_ed25519_${USERNAME} && echo PRIVATE_KEY_COPIED"
                                        $copyPrivateKeyJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $copyPrivateKeyCommand
                                        
                                        if (Wait-Job $copyPrivateKeyJob -Timeout 15) {
                                            $privateKeyCopyResult = Receive-Job $copyPrivateKeyJob
                                            Remove-Job $copyPrivateKeyJob
                                        } else {
                                            Remove-Job $copyPrivateKeyJob -Force
                                            $privateKeyCopyResult = "Private key copy timed out after 15 seconds"
                                        }
                                        
                                        if ($privateKeyCopyResult -match "PRIVATE_KEY_COPIED") {
                                            # Verify the private key was actually copied as a file
                                            $verifyPrivateKeyCommand = "test -f ~/.ssh/id_ed25519_${USERNAME} && echo PRIVATE_KEY_FILE_EXISTS || echo PRIVATE_KEY_FILE_MISSING"
                                            $verifyPrivateKeyJob = Start-Job -ScriptBlock {
                                                param($sshKeyPath, $remoteHost, $command)
                                                $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                                return $result
                                            } -ArgumentList $sshKeyPath, $remoteHost, $verifyPrivateKeyCommand
                                            
                                            if (Wait-Job $verifyPrivateKeyJob -Timeout 15) {
                                                $privateKeyVerifyResult = Receive-Job $verifyPrivateKeyJob
                                                Remove-Job $verifyPrivateKeyJob
                                            } else {
                                                Remove-Job $verifyPrivateKeyJob -Force
                                                $privateKeyVerifyResult = "Private key verification timed out after 15 seconds"
                                            }
                                            
                                            if ($privateKeyVerifyResult -match "PRIVATE_KEY_FILE_EXISTS") {
                                                Write-Host "    [SUCCESS] Private key copied and verified as file on remote system" -ForegroundColor Green
                                            } else {
                                                Write-Host "    [ERROR] Private key was not properly copied as file: $privateKeyVerifyResult" -ForegroundColor Red
                                            }
                                        } else {
                                            Write-Host "    [ERROR] Failed to copy private key: $privateKeyCopyResult" -ForegroundColor Red
                                        }
                                    } else {
                                        Write-Host "    [ERROR] Private key not found at: $sshPrivateKeyPath" -ForegroundColor Red
                                    }
                                    
                                    # Copy known_hosts file if it exists
                                    if (Test-Path $sshKnownHostsPath) {
                                        $knownHostsContent = Get-Content $sshKnownHostsPath -Raw
                                        $knownHostsBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($knownHostsContent))
                                        
                                        # Remove any existing file/directory that might be in the way
                                        $cleanupKnownHostsCommand = "rm -rf ~/.ssh/known_hosts"
                                        $cleanupKnownHostsJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $cleanupKnownHostsCommand
                                        
                                        if (Wait-Job $cleanupKnownHostsJob -Timeout 15) {
                                            Receive-Job $cleanupKnownHostsJob | Out-Null
                                            Remove-Job $cleanupKnownHostsJob
                                        } else {
                                            Remove-Job $cleanupKnownHostsJob -Force
                                            Write-Host "    [WARNING] known_hosts cleanup timed out after 15 seconds" -ForegroundColor Yellow
                                        }
                                        
                                        # Copy known_hosts to remote system
                                        $copyKnownHostsCommand = "echo '$knownHostsBase64' | base64 -d > ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && echo KNOWN_HOSTS_COPIED"
                                        $copyKnownHostsJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $copyKnownHostsCommand
                                        
                                        if (Wait-Job $copyKnownHostsJob -Timeout 15) {
                                            $knownHostsCopyResult = Receive-Job $copyKnownHostsJob
                                            Remove-Job $copyKnownHostsJob
                                        } else {
                                            Remove-Job $copyKnownHostsJob -Force
                                            $knownHostsCopyResult = "known_hosts copy timed out after 15 seconds"
                                        }
                                        
                                        if ($knownHostsCopyResult -match "KNOWN_HOSTS_COPIED") {
                                            # Verify the known_hosts was actually copied as a file
                                            $verifyKnownHostsCommand = "test -f ~/.ssh/known_hosts && echo KNOWN_HOSTS_FILE_EXISTS || echo KNOWN_HOSTS_FILE_MISSING"
                                            $verifyKnownHostsJob = Start-Job -ScriptBlock {
                                                param($sshKeyPath, $remoteHost, $command)
                                                $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                                return $result
                                            } -ArgumentList $sshKeyPath, $remoteHost, $verifyKnownHostsCommand
                                            
                                            if (Wait-Job $verifyKnownHostsJob -Timeout 15) {
                                                $knownHostsVerifyResult = Receive-Job $verifyKnownHostsJob
                                                Remove-Job $verifyKnownHostsJob
                                            } else {
                                                Remove-Job $verifyKnownHostsJob -Force
                                                $knownHostsVerifyResult = "known_hosts verification timed out after 15 seconds"
                                            }
                                            
                                            if ($knownHostsVerifyResult -match "KNOWN_HOSTS_FILE_EXISTS") {
                                                Write-Host "    [SUCCESS] known_hosts file copied and verified as file on remote system" -ForegroundColor Green
                                            } else {
                                                Write-Host "    [ERROR] known_hosts was not properly copied as file: $knownHostsVerifyResult" -ForegroundColor Red
                                            }
                                        } else {
                                            Write-Host "    [ERROR] Failed to copy known_hosts: $knownHostsCopyResult" -ForegroundColor Red
                                        }
                                    } else {
                                        Write-Host "    [INFO] known_hosts file not found, creating empty one on remote" -ForegroundColor Cyan
                                        # Remove any existing directory and create empty file
                                        $createKnownHostsCommand = "rm -rf ~/.ssh/known_hosts && touch ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts"
                                        $createKnownHostsJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $createKnownHostsCommand
                                        
                                        if (Wait-Job $createKnownHostsJob -Timeout 15) {
                                            Receive-Job $createKnownHostsJob | Out-Null
                                            Remove-Job $createKnownHostsJob
                                        } else {
                                            Remove-Job $createKnownHostsJob -Force
                                            Write-Host "    [WARNING] known_hosts creation timed out after 15 seconds" -ForegroundColor Yellow
                                        }
                                        
                                        # Verify it was created as a file
                                        $verifyKnownHostsCommand = "test -f ~/.ssh/known_hosts && echo KNOWN_HOSTS_FILE_EXISTS || echo KNOWN_HOSTS_FILE_MISSING"
                                        $verifyKnownHostsJob = Start-Job -ScriptBlock {
                                            param($sshKeyPath, $remoteHost, $command)
                                            $result = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $command 2>&1
                                            return $result
                                        } -ArgumentList $sshKeyPath, $remoteHost, $verifyKnownHostsCommand
                                        
                                        if (Wait-Job $verifyKnownHostsJob -Timeout 15) {
                                            $knownHostsVerifyResult = Receive-Job $verifyKnownHostsJob
                                            Remove-Job $verifyKnownHostsJob
                                        } else {
                                            Remove-Job $verifyKnownHostsJob -Force
                                            $knownHostsVerifyResult = "known_hosts verification timed out after 15 seconds"
                                        }
                                        
                                        if ($knownHostsVerifyResult -match "KNOWN_HOSTS_FILE_EXISTS") {
                                            Write-Host "    [SUCCESS] Empty known_hosts file created on remote system" -ForegroundColor Green
                                        } else {
                                            Write-Host "    [ERROR] Failed to create known_hosts file: $knownHostsVerifyResult" -ForegroundColor Red
                                        }
                                    }
                                    
                                    Write-Host "  [INFO] SSH files setup complete for Docker container mounting" -ForegroundColor Cyan
                                    Write-Host ""
                                    
                                    # Now test Docker availability since SSH authentication is working
                                    Write-Host "[INFO] Testing Docker availability on remote host..." -ForegroundColor Cyan
                                    Write-Host ""
                                    
                                    # Use PowerShell job with timeout for Docker version check
                                    $dockerTestJob = Start-Job -ScriptBlock {
                                        param($sshKeyPath, $remoteHost)
                                        $result = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker --version" 2>&1
                                        return @{
                                            Output = $result
                                            ExitCode = $LASTEXITCODE
                                        }
                                    } -ArgumentList $sshKeyPath, $remoteHost
                                    
                                    if (Wait-Job $dockerTestJob -Timeout 15) {
                                        $jobResult = Receive-Job $dockerTestJob
                                        Remove-Job $dockerTestJob
                                        $dockerTestResult = $jobResult.Output
                                        $dockerExitCode = $jobResult.ExitCode
                                    } else {
                                        Remove-Job $dockerTestJob -Force
                                        $dockerTestResult = "Docker version check timed out after 15 seconds"
                                        $dockerExitCode = 1
                                    }
                                    
                                    if ($dockerExitCode -eq 0 -and $dockerTestResult -notmatch "Permission denied") {
                                        Write-Host "[SUCCESS] Docker is available on remote host" -ForegroundColor Green
                                        Write-Host "  Version: $dockerTestResult"
                                        Write-Host ""
                                    } else {
                                        Write-Host "[WARNING] Docker test failed on remote host" -ForegroundColor Yellow
                                        Write-Host "  Error: $dockerTestResult"
                                        Write-Host ""
                                        Write-Host "[INFO] This could indicate:" -ForegroundColor Yellow
                                        Write-Host "  - Docker is not installed on the remote host"
                                        Write-Host "  - Docker service is not running"
                                        Write-Host "  - User does not have permission to run Docker"
                                        Write-Host "  - Remote system needs additional setup"
                                        Write-Host ""
                                        Write-Host "[INFO] SSH authentication is working, so you can continue with manual Docker setup if needed" -ForegroundColor Cyan
                                        Write-Host ""
                                    }
                                    
                                    # Extract IP address from remote host string
                                    $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                                    $script:RemoteHostIp = $remoteIP
                                    
                                    Write-Host "[SUCCESS] Remote SSH setup completed successfully!" -ForegroundColor Green
                                    Write-Host "  Host: $remoteHost"
                                    Write-Host "  Authentication: SSH Key-based (passwordless)"
                                    Write-Host "  Ready for Docker operations"
                                    Write-Host ""
                                    
                                } else {
                                    Write-Host ""
                                    Write-Host "  [WARNING] Passwordless SSH still not working after $maxRetries attempts" -ForegroundColor Yellow
                                    Write-Host "  Last response: $finalTest" -ForegroundColor Yellow
                                    Write-Host ""
                                    Write-Host "  [INFO] This could indicate:" -ForegroundColor Cyan
                                    Write-Host "  - SSH service needs more time to reload configuration"
                                    Write-Host "  - Remote host has strict SSH key requirements"
                                    Write-Host "  - authorized_keys file permissions may need adjustment"
                                    Write-Host "  - SELinux or similar security policies blocking key authentication"
                                    Write-Host ""
                                    Write-Host "  [INFO] Key was copied, so passwordless auth may work later" -ForegroundColor Cyan
                                    Write-Host "  Continuing with current authentication setup..." -ForegroundColor Cyan
                                    Write-Host ""
                                    
                                    # Still set up the IP for remote operations, but note authentication status
                                    $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                                    $script:RemoteHostIp = $remoteIP
                                    
                                    Write-Host "  [INFO] Remote host configured for password-based operations" -ForegroundColor Cyan
                                    Write-Host "  Host: $remoteHost"
                                    Write-Host "  Authentication: SSH Key copied (passwordless may work later)"
                                    Write-Host ""
                                }
                        } else {
                            Write-Host ""
                            Write-Host "  [WARNING] Failed to copy SSH key to remote host with all available methods" -ForegroundColor Yellow
                            Write-Host "  Password authentication will be required for future connections"
                            Write-Host ""
                            Write-Host "  [INFO] Please ensure:" -ForegroundColor Cyan
                            Write-Host "  - SSH service is running on remote host" -ForegroundColor Cyan
                            Write-Host "  - Password authentication is enabled" -ForegroundColor Cyan
                            Write-Host "  - User has permissions to write to ~/.ssh directory" -ForegroundColor Cyan
                            Write-Host "  - Consider installing Posh-SSH: Install-Module Posh-SSH -Scope CurrentUser" -ForegroundColor Cyan
                            Write-Host ""
                        }
                    } else {
                        Write-Host ""
                        Write-Host "  [ERROR] SSH public key not found at: $sshPublicKeyPath" -ForegroundColor Red
                        Write-Host "  Cannot set up passwordless authentication"
                        Write-Host ""
                        
                        # Still set IP address for potential manual setup
                        $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                        $script:RemoteHostIp = $remoteIP
                    }
                    
                    # Extract IP address and continue (for successful key copy cases)
                    if (-not $script:RemoteHostIp) {
                        $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                        $script:RemoteHostIp = $remoteIP
                    }
                    
                    # Secure cleanup: Clear the credential object from memory
                    $remoteCredential = $null
                    $securePassword = $null
                    [System.GC]::Collect()
                    Write-Host ""
                    Write-Host "  [INFO] Credentials securely cleared from memory" -ForegroundColor Cyan
                    Write-Host ""
                    
                } catch {
                    # Secure cleanup: Clear the credential object from memory on exception
                    if ($remoteCredential) {
                        $remoteCredential = $null
                        $securePassword = $null
                        [System.GC]::Collect()
                    }

                    Write-Host ""
                    Write-Host "  [ERROR] Failed to copy SSH key" -ForegroundColor Red
                    Write-Host "  Details: $($_.Exception.Message)"
                    Write-Host ""
                    [System.Windows.Forms.MessageBox]::Show("Failed to copy SSH key for passwordless authentication.`n`nError: $($_.Exception.Message)`n`nPlease ensure:`n- SSH service is running`n- Password is correct`n- User has proper permissions", "SSH Key Copy Error", "OK", "Error")
                    return
                }
                
            } else {
                Write-Host ""
                Write-Host "  [INFO] User cancelled password authentication" -ForegroundColor Cyan
                Write-Host ""
                # No credentials to clean up since user cancelled
                return
            }
        }

    } catch {
        Write-Host ""
        Write-Host "[ERROR] Unexpected error during SSH connection test" -ForegroundColor Red
        Write-Host "  Details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Unexpected error during remote connection test.`n`nError: $($_.Exception.Message)", "Connection Error", "OK", "Error")
        return
    }
    
    try {
        if ($SSHEXITCODE -eq 0){
            # SSH key authentication succeeded - extract IP and continue
            Write-Host "[INFO] SSH key authentication already working, proceeding with Docker setup..." -ForegroundColor Cyan
            
            # Extract IP address from remote host string
            $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
            $script:RemoteHostIp = $remoteIP
        }
    } catch {
        Write-Host ""
        Write-Host "[ERROR] Docker unavailable on remote host" -ForegroundColor Red
        Write-Host "  Host: $remoteHost"
        Write-Host "  Details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Docker is not available on the remote host.`n`nPlease ensure Docker is installed and configured properly.", "Connection Error", "OK", "Error")
        return
    }
            
    # Set dialog result and close with all checks successfully passed
    $formConnection.DialogResult = [System.Windows.Forms.DialogResult]::No
    $formConnection.Close()   
})

# Show the connection selection dialog
Write-Debug-Message "[DEBUG] Displaying container location selection dialog"
$connectionResult = $formConnection.ShowDialog()
Write-Debug-Message "[DEBUG] Container location dialog result: $connectionResult"

# Store the selection for later use
if ($connectionResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    Write-Debug-Message "[DEBUG] Processing local container selection"
    $CONTAINER_LOCATION = "LOCAL"
    Write-Host ""
    Write-Host "[SUCCESS] Container location configured" -ForegroundColor Green
    Write-Host "  Location: LOCAL"
    Write-Host "  Mode: Local Docker containers"
    Write-Host ""
    Write-Host "========================================="
    Write-Host ""
} elseif ($connectionResult -eq [System.Windows.Forms.DialogResult]::No -and $script:RemoteHostIp) {
    Write-Debug-Message "[DEBUG] Processing remote container selection for IP: $($script:RemoteHostIp)"
    $CONTAINER_LOCATION = "REMOTE@$($script:RemoteHostIp)"
    Write-Host "[SUCCESS] Container location configured" -ForegroundColor Green
    Write-Host "  Location: REMOTE"
    Write-Host "  Target: $($script:RemoteHostIp)"
    Write-Host "  Mode: Remote Docker containers via SSH"
    Write-Host ""
    
    # Set up global SSH environment for all remote Docker operations
    $script:SshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
    $env:DOCKER_SSH_OPTS = "-i `"$script:SshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
    Write-Debug-Message "[DEBUG] Configuring global SSH environment for Docker operations"
    Write-Debug-Message "[DEBUG] SSH Key Path: $script:SshKeyPath"
    Write-Debug-Message "[DEBUG] SSH Options: $env:DOCKER_SSH_OPTS"
    Write-Host "[INFO] Global SSH environment configured for Docker operations" -ForegroundColor Cyan
    Write-Host "  SSH Key: $script:SshKeyPath" -ForegroundColor Cyan
    Write-Host "  SSH Options: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Debug-Message "[DEBUG] Container location configuration failed"
    Write-Debug-Message "[DEBUG] Connection result: $connectionResult, Remote IP: $($script:RemoteHostIp)"
    Write-Host ""
    Write-Host "[ERROR] Configuration failed" -ForegroundColor Red
    Write-Host "  Reason: Remote connection failed or user cancelled"
    Write-Host ""
    exit 1
}


#--------------------------------------------#
#   STEP 4.1.2: IF REMOTE - READ REPO LIST   #
#--------------------------------------------#

Write-Debug-Message "[DEBUG] STEP 4.1.2: Starting remote repository scanning..."

if($CONTAINER_LOCATION -eq "REMOTE@$($script:RemoteHostIp)") {
    Write-Debug-Message "[DEBUG] Container location confirmed as remote: $CONTAINER_LOCATION"
    Write-Host ""
    Write-Host "========================================="
    Write-Host "    SCANNING REMOTE REPOSITORIES"
    Write-Host "========================================="
    Write-Host ""
    
    Write-Host "    [INFO] Scanning remote host for available repositories..." -ForegroundColor Cyan
    
    # Define the base path on remote host where repositories are stored
    $remoteRepoPath = "/home/php-workstation/Schreibtisch/Repositories"
    Write-Debug-Message "[DEBUG] Remote repository base path: $remoteRepoPath"
    #$remoteHost = "php_workstation@$($script:RemoteHostIp)" TODO: CHECK IF NEEDED
    
    try {
        Write-Debug-Message "[DEBUG] Starting remote directory scan process"
        # Scan for subdirectories on remote host
        Write-Host ""
        Write-Host "    Scanning directory: $remoteRepoPath"
        Write-Host "    Using remote host: $remoteHost"
        Write-Host ""
        
        # Ensure we're using the correct remote host (the one we authenticated with)
        Write-Debug-Message "[DEBUG] Validating remote host configuration..."
        if ([string]::IsNullOrEmpty($remoteHost)) {
            Write-Debug-Message "[DEBUG] Remote host variable empty, reconstructing from stored IP"
            # Reconstruct the remote host from the IP we stored earlier
            if ($script:RemoteHostIp) {
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                Write-Debug-Message "[DEBUG] Reconstructed remote host: $remoteHost"
                Write-Host ""
                Write-Host "    [INFO] Reconstructed remote host: $remoteHost" -ForegroundColor Cyan
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "    [ERROR] No remote host information available" -ForegroundColor Red
                throw "Remote host configuration is missing"
            }
        }
        
        $scanCommand = "find '$remoteRepoPath' -maxdepth 1 -type d -not -path '$remoteRepoPath' -exec basename {} \;"
        Write-Debug-Message "[DEBUG] Repository scan command: $scanCommand"
        
        # Use the authenticated SSH connection with specific key
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        Write-Debug-Message "[DEBUG] Using SSH key for scan: $sshKeyPath"
        Write-Host ""
        Write-Host "    Executing: ssh with key $sshKeyPath to $remoteHost '$scanCommand'"
        Write-Host ""
        
        # Use job with timeout for repository scanning to prevent hanging
        Write-Debug-Message "[DEBUG] Starting repository scan job with 20-second timeout"
        $scanJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost, $scanCommand)
            $output = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost $scanCommand 2>&1
            @{
                Output = $output
                ExitCode = $LASTEXITCODE
            }
        } -ArgumentList $sshKeyPath, $remoteHost, $scanCommand
        
        Write-Debug-Message "[DEBUG] Scan job started, waiting for completion..."
        $scanResult = Wait-Job $scanJob -Timeout 20
        
        if ($scanResult) {
            Write-Debug-Message "[DEBUG] Scan job completed successfully, retrieving results"
            $scanData = Receive-Job $scanJob
            $availableFolders = $scanData.Output
            $scanExitCode = $scanData.ExitCode
            Write-Debug-Message "[DEBUG] Scan exit code: $scanExitCode"
            Write-Debug-Message "[DEBUG] Raw scan output: $availableFolders"
            Remove-Job $scanJob
        } else {
            Write-Debug-Message "[DEBUG] Scan job timed out, cleaning up"
            Write-Host "    [ERROR] Repository scan timed out" -ForegroundColor Red
            Stop-Job $scanJob -ErrorAction SilentlyContinue
            Remove-Job $scanJob -ErrorAction SilentlyContinue
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Repository scan timed out after 20 seconds.`n`nThis may indicate network connectivity issues or the remote directory scan is taking too long.", "Scan Timeout", "OK", "Error")
            exit 1
        }
        
        if ($scanExitCode -ne 0) {
            Write-Debug-Message "[DEBUG] Repository scan failed with exit code: $scanExitCode"
            Write-Debug-Message "[DEBUG] Scan error output: $availableFolders"
            Write-Host ""
            Write-Host "    [ERROR] Could not scan remote directory" -ForegroundColor Red
            Write-Host "    Command output: $availableFolders"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Could not scan remote directory: $remoteRepoPath`n`nPlease ensure the directory exists and is accessible.", "Remote Scan Error", "OK", "Error")
            exit 1
        }
        
        # Convert output to array and filter out empty lines
        $folderList = $availableFolders -split "`n" | Where-Object { $_.Trim() -ne "" }
        Write-Debug-Message "[DEBUG] Processed folder list: Found $($folderList.Count) folders"
        Write-Debug-Message "[DEBUG] Folder list contents: $($folderList -join ', ')"
        
        if ($folderList.Count -eq 0) {
            Write-Debug-Message "[DEBUG] No repositories found in remote directory"
            Write-Host ""
            Write-Host "    [ERROR] No subdirectories (and thus no simulation models) found in:" -ForegroundColor Red
            Write-Host "    $remoteRepoPath"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("No subdirectories (and thus no simulation models) found in: $remoteRepoPath`n`nPlease ensure there are subdirectories containing your simulation models and their respective GitHub repositories.", "No Repositories Found", "OK", "Warning")
            exit 1
        }
        
        Write-Debug-Message "[DEBUG] Repository scan completed successfully: $($folderList.Count) repositories found"
        Write-Host ""
        Write-Host "    [SUCCESS] Found $($folderList.Count) repositories:" -ForegroundColor Green
        Write-Host ""
        foreach ($folder in $folderList) {
            Write-Host "        - $folder"
        }
        Write-Host ""
        
    } catch {
        Write-Host ""
        Write-Host "    [ERROR] Unexpected error while scanning remote repositories" -ForegroundColor Red
        Write-Debug-Message "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Unexpected error while scanning remote for simulation models and repositories.`n`nError: $($_.Exception.Message)", "Scan Error", "OK", "Error")
        exit 1
    }

#---------------------------------------------------#
#   STEP 4.1.3: IF REMOTE - PROMPT REPO SELECTION   #
#---------------------------------------------------#

    Write-Debug-Message "[DEBUG] STEP 4.1.3: Starting repository selection process..."
    
    Write-Host ""
    Write-Host "========================================="
    Write-Host "    REPOSITORY SELECTION"
    Write-Host "========================================="
    Write-Host ""
    Write-Host "    [INFO] Creating repository selection dialog..." -ForegroundColor Cyan
    Write-Host ""
    
    Write-Debug-Message "[DEBUG] Creating repository selection form with $($folderList.Count) options"
    
    # Create repository selection form
    $formRepoSelection = New-Object System.Windows.Forms.Form -Property @{ 
        Text = 'Select Repository - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(500,400)
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }
    Set-FormCenterOnCurrentScreen -Form $formRepoSelection

    # Instruction label
    $labelRepoInstruction = New-Object System.Windows.Forms.Label -Property @{ 
        Text = "Please select the repository/model folder you want to work with:"
        Location = New-Object System.Drawing.Point(10,10)
        Size = New-Object System.Drawing.Size(470,30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Regular)
    }
    $formRepoSelection.Controls.Add($labelRepoInstruction)

    # Create ListBox for repository selection
    $listBoxRepos = New-Object System.Windows.Forms.ListBox -Property @{
        Location = New-Object System.Drawing.Point(10,50)
        Size = New-Object System.Drawing.Size(470,250)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        SelectionMode = 'One'
    }
    
    # Add folders to the list
    Write-Debug-Message "[DEBUG] Populating repository list with folders..."
    foreach ($folder in $folderList) {
        $listBoxRepos.Items.Add($folder) | Out-Null
        Write-Debug-Message "[DEBUG] Added repository: $folder"
    }
    
    # Select first item by default
    if ($listBoxRepos.Items.Count -gt 0) {
        $listBoxRepos.SelectedIndex = 0
        Write-Debug-Message "[DEBUG] Default selection set to: $($listBoxRepos.Items[0])"
    }
    
    $formRepoSelection.Controls.Add($listBoxRepos)

    # Add OK and Cancel buttons
    $buttonRepoOK = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Select Repository'
        Location = New-Object System.Drawing.Point(250,320)
        Size = New-Object System.Drawing.Size(120,30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    }
    $formRepoSelection.Controls.Add($buttonRepoOK)

    $buttonRepoCancel = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Cancel'
        Location = New-Object System.Drawing.Point(380,320)
        Size = New-Object System.Drawing.Size(75,30)
        DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    }
    $formRepoSelection.Controls.Add($buttonRepoCancel)

    # Set default buttons
    $formRepoSelection.AcceptButton = $buttonRepoOK
    $formRepoSelection.CancelButton = $buttonRepoCancel

    # Add click handler for OK button
    $buttonRepoOK.Add_Click({
        if ($listBoxRepos.SelectedIndex -ge 0) {
            $script:SelectedRepo = $listBoxRepos.SelectedItem
            $formRepoSelection.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $formRepoSelection.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show('Please select a simulation model repository from the list.', 'No Selection', 'OK', 'Warning')
        }
    })

    # Show the repository selection dialog
    Write-Debug-Message "[DEBUG] Displaying repository selection dialog to user"
    $repoSelectionResult = $formRepoSelection.ShowDialog()
    Write-Debug-Message "[DEBUG] Repository selection dialog result: $repoSelectionResult"

    # Process the selection
    if ($repoSelectionResult -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Debug-Message "[DEBUG] User selected repository: $($script:SelectedRepo)"
        Write-Host ""
        Write-Host "    [SUCCESS] Selected repository: $($script:SelectedRepo)" -ForegroundColor Green
        Write-Host "    Repository path: $remoteRepoPath/$($script:SelectedRepo)"
        Write-Host ""
        
        # Verify the selected repository exists and contains a Git repository
        Write-Host "    [INFO] Verifying selected repository..." -ForegroundColor Cyan
        
        # Ensure we're using the correct remote host for verification
        if ([string]::IsNullOrEmpty($remoteHost)) {
            if ($script:RemoteHostIp) {
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                Write-Host ""
                Write-Host "    [INFO] Using remote host: $remoteHost" -ForegroundColor Cyan
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "    [ERROR] No remote host information available for verification" -ForegroundColor Red
                Write-Host ""
            }
        }
        
        $gitCheckCommand = "test -d '$remoteRepoPath/$($script:SelectedRepo)/.git' && echo 'Git repository found' || echo 'No Git repository'"
        
        # Use job with timeout for git check to prevent hanging
        Write-Host "    [INFO] Checking for .git directory in selected repository..." -ForegroundColor Cyan
        $gitCheckJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost, $gitCheckCommand)
            & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost $gitCheckCommand 2>&1
        } -ArgumentList $sshKeyPath, $remoteHost, $gitCheckCommand
        
        $gitCheckResult = Wait-Job $gitCheckJob -Timeout 15
        
        if ($gitCheckResult) {
            $gitCheckOutput = Receive-Job $gitCheckJob
            Remove-Job $gitCheckJob
        } else {
            Write-Host "    [WARNING] Git repository check timed out" -ForegroundColor Yellow
            Stop-Job $gitCheckJob -ErrorAction SilentlyContinue
            Remove-Job $gitCheckJob -ErrorAction SilentlyContinue
            $gitCheckOutput = "Timeout occurred"
        }
        
        if ($gitCheckOutput -match "Git repository found") {
            Write-Host ""
            Write-Host "    [SUCCESS] Git repository found in selected folder" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host ""
            if ($gitCheckOutput -match "Timeout occurred") {
                Write-Host "    [WARNING] Could not verify git repository due to timeout" -ForegroundColor Yellow
                Write-Host "    The repository verification timed out - continuing anyway"
            } else {
                Write-Host "    [WARNING] No .git directory found in selected folder" -ForegroundColor Yellow
                Write-Host "    This folder may not be a Git repository"
            }
            Write-Host ""
        }
        Write-Host ""
        
    } else {
        Write-Host ""
        Write-Host "    [ERROR] User cancelled repository selection" -ForegroundColor Red
        Write-Host ""
        exit 1
    }

#---------------------------------------------------#
#   STEP 4.1.4: IF REMOTE - DOCKER CONTEXT LOGIC    #
#---------------------------------------------------#

    Write-Host ""
    Write-Host "========================================="
    Write-Host "    REMOTE DOCKER CONTEXT SETUP"
    Write-Host "========================================="
    Write-Host ""
    
    Write-Host "    [INFO] Setting up Docker context for remote execution..." -ForegroundColor Cyan
    Write-Host "    Remote host: $remoteHost"
    Write-Host "    Selected repository: $($script:SelectedRepo)"
    Write-Host "    Remote repository path: $remoteRepoPath/$($script:SelectedRepo)"
    Write-Host ""

    # Store the full remote path for later use
    $script:RemoteRepoPath = "$remoteRepoPath/$($script:SelectedRepo)"
    
    # Verify Docker is available on remote host
    Write-Host ""
    Write-Host "    [INFO] Checking remote Docker availability..." -ForegroundColor Cyan
    Write-Host ""
    try {
        # Ensure we have the correct remote host for Docker verification
        if ([string]::IsNullOrEmpty($remoteHost)) {
            if ($script:RemoteHostIp) {
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                Write-Host ""
                Write-Host "    [INFO] Using remote host for Docker verification: $remoteHost" -ForegroundColor Cyan
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "    [ERROR] No remote host information available for Docker verification" -ForegroundColor Red
                Write-Host ""
                exit 1
            }
        }
        
        $dockerVersion = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker --version" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "    [SUCCESS] Docker is available on remote host" -ForegroundColor Green
            Write-Host "    Remote Docker version: $dockerVersion"
            Write-Host ""
            
            # Ensure Docker engine is running on remote host
            Write-Host ""
            Write-Host "    [INFO] Checking remote Docker engine status..." -ForegroundColor Cyan
            Write-Host ""
            
            # Use job with timeout for remote docker info to prevent hanging
            $remoteDockerJob = Start-Job -ScriptBlock {
                param($sshKeyPath, $remoteHost)
                & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker info" 2>&1 | Out-Null
                $LASTEXITCODE
            } -ArgumentList $sshKeyPath, $remoteHost
            
            $remoteDockerResult = Wait-Job $remoteDockerJob -Timeout 15
            
            if ($remoteDockerResult) {
                $remoteExitCode = Receive-Job $remoteDockerJob
                Remove-Job $remoteDockerJob
            } else {
                Write-Host "    [WARNING] Remote Docker info command timed out" -ForegroundColor Yellow
                Stop-Job $remoteDockerJob -ErrorAction SilentlyContinue
                Remove-Job $remoteDockerJob -ErrorAction SilentlyContinue
                $remoteExitCode = 1  # Treat timeout as failure
            }
            
            if ($remoteExitCode -ne 0) {
                Write-Host ""
                Write-Host "    [WARNING] Docker engine is not running on remote host" -ForegroundColor Yellow
                Write-Host "    Attempting to start Docker service on Ubuntu 24.04..."
                Write-Host ""
                
                try {
                    # Try to start Docker service on Ubuntu (systemd)
                    # First, check if user can run Docker without sudo (is in docker group)
                    Write-Host ""
                    Write-Host "    Checking if user can run Docker without sudo..."
                    Write-Host ""
                    $dockerGroupCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "groups | grep -q docker && echo 'HAS_DOCKER_GROUP' || echo 'NO_DOCKER_GROUP'" 2>&1
                    
                    if ($dockerGroupCheck -match "HAS_DOCKER_GROUP") {
                        Write-Host ""
                        Write-Host "    [INFO] User is in docker group, trying Docker without sudo..." -ForegroundColor Cyan
                        Write-Host ""
                        # Try starting Docker service as regular user (if systemd allows)
                        $startResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "systemctl --user start docker || echo 'USER_START_FAILED'" 2>&1
                        if ($startResult -match "USER_START_FAILED") {
                            Write-Host ""
                            Write-Host "    [INFO] User-level start failed, need system-level Docker service" -ForegroundColor Cyan
                            Write-Host ""
                            $needsSudo = $true
                        } else {
                            Write-Host ""
                            Write-Host "    [SUCCESS] Docker service started at user level" -ForegroundColor Green
                            Write-Host ""
                            $needsSudo = $false
                        }
                    } else {
                        Write-Host ""
                        Write-Host "    [INFO] User not in docker group, system-level service required" -ForegroundColor Cyan
                        Write-Host ""
                        $needsSudo = $true
                    }
                    
                    if ($needsSudo) {
                        Write-Host ""
                        Write-Host "    [INFO] System-level Docker service management required" -ForegroundColor Cyan
                        Write-Host "    Checking sudo access for Docker service..."
                        Write-Host ""

                        # Check if passwordless sudo is available for systemctl docker
                        $sudoCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "sudo -n systemctl status docker >/dev/null 2>&1 && echo 'SUDO_OK' || echo 'SUDO_NEEDS_PASSWORD'" 2>&1
                        
                        if ($sudoCheck -match "SUDO_OK") {
                            Write-Host ""
                            Write-Host "    [SUCCESS] Passwordless sudo available for Docker service" -ForegroundColor Green
                            Write-Host ""
                            $startResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "sudo systemctl start docker" 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host ""
                                Write-Host "    [SUCCESS] Docker service started via sudo" -ForegroundColor Green
                                Write-Host ""
                            } else {
                                Write-Host ""
                                Write-Host "    [WARNING] Could not start Docker service via sudo: $startResult" -ForegroundColor Yellow
                                Write-Host ""
                            }
                        } else {
                            Write-Host ""
                            Write-Host "    [WARNING] Sudo requires password for Docker service management" -ForegroundColor Yellow
                            Write-Host "    Cannot start Docker service automatically via SSH batch mode"
                            Write-Host ""

                            # Provide user with manual instructions
                            [System.Windows.Forms.MessageBox]::Show(
                                "Docker service needs to be started on the remote host, but sudo requires a password.`n`n" +
                                "Please manually run on the remote host:`n`n" +
                                "sudo systemctl start docker`n" +
                                "sudo systemctl enable docker`n`n" +
                                "OR add your user to the docker group:`n`n" +
                                "sudo usermod -aG docker `$USER`n" +
                                "newgrp docker`n`n" +
                                "Then click OK to continue.",
                                "Manual Docker Setup Required",
                                "OK",
                                "Information"
                            )
                        }
                    }
                    
                    # Wait for Docker daemon to start with progress indication
                    Write-Host ""
                    Write-Host "    Waiting for remote Docker daemon to initialize..."
                    Write-Host ""
                    $maxAttempts = 30  # 30 seconds max wait
                    $attempt = 0
                    
                    do {
                        Start-Sleep -Seconds 1
                        $attempt++
                        Write-Host "    Checking remote Docker daemon status... ($attempt/$maxAttempts)" -NoNewline
                        
                        # Use job with timeout for remote docker info check
                        $remoteCheckJob = Start-Job -ScriptBlock {
                            param($sshKeyPath, $remoteHost)
                            & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker info" 2>&1 | Out-Null
                            $LASTEXITCODE
                        } -ArgumentList $sshKeyPath, $remoteHost
                        
                        $remoteCheckResult = Wait-Job $remoteCheckJob -Timeout 8
                        
                        if ($remoteCheckResult) {
                            $remoteCheckExitCode = Receive-Job $remoteCheckJob
                            Remove-Job $remoteCheckJob
                            
                            if ($remoteCheckExitCode -eq 0) {
                                Write-Host " [SUCCESS]" -ForegroundColor Green
                                break
                            } else {
                                Write-Host ""
                            }
                        } else {
                            Write-Host " [TIMEOUT]"
                            Stop-Job $remoteCheckJob -ErrorAction SilentlyContinue
                            Remove-Job $remoteCheckJob -ErrorAction SilentlyContinue
                        }
                        
                        # Show different messages at different intervals
                        if ($attempt -eq 10) {
                            Write-Host ""
                            Write-Host "    [INFO] Remote Docker is still starting up (this may take a moment)..." -ForegroundColor Cyan
                            Write-Host ""
                        } elseif ($attempt -eq 20) {
                            Write-Host ""
                            Write-Host "    [INFO] Still waiting for remote Docker daemon (almost ready)..." -ForegroundColor Cyan
                            Write-Host ""
                        }
                        
                    } while ($attempt -lt $maxAttempts)
                    
                    # Final check with timeout
                    $remoteFinalJob = Start-Job -ScriptBlock {
                        param($sshKeyPath, $remoteHost)
                        & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker info" 2>&1 | Out-Null
                        $LASTEXITCODE
                    } -ArgumentList $sshKeyPath, $remoteHost
                    
                    $remoteFinalResult = Wait-Job $remoteFinalJob -Timeout 8
                    
                    if ($remoteFinalResult) {
                        $remoteFinalExitCode = Receive-Job $remoteFinalJob
                        Remove-Job $remoteFinalJob
                    } else {
                        Write-Host "    [WARNING] Final remote Docker check timed out" -ForegroundColor Yellow
                        Stop-Job $remoteFinalJob -ErrorAction SilentlyContinue
                        Remove-Job $remoteFinalJob -ErrorAction SilentlyContinue
                        $remoteFinalExitCode = 1
                    }
                    
                    if ($remoteFinalExitCode -eq 0) {
                        Write-Host ""
                        Write-Host "    [SUCCESS] Remote Docker engine started successfully!" -ForegroundColor Green
                        Write-Host "    Startup time: $attempt seconds"
                        Write-Host ""
                    } else {
                        Write-Host ""
                        Write-Host "    [WARNING] Remote Docker engine did not start within $maxAttempts seconds" -ForegroundColor Yellow
                        Write-Host "    Please check Docker service on remote host manually"
                        Write-Host ""
                        
                        # Offer user choice to continue or exit
                        $choice = [System.Windows.Forms.MessageBox]::Show(
                            "Remote Docker engine could not be started automatically.`n`nWould you like to:`n- Click 'Yes' to continue anyway (may cause errors)`n- Click 'No' to check manually and try again`n- Click 'Cancel' to exit",
                            "Remote Docker Startup Issue",
                            "YesNoCancel",
                            "Warning"
                        )
                        
                        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
                            Write-Host ""
                            Write-Host "    [INFO] Please start Docker on remote host manually" -ForegroundColor Cyan
                            Write-Host ""
                            [System.Windows.Forms.MessageBox]::Show("Please start Docker on the remote host manually:`n`nsudo systemctl start docker`nsudo systemctl enable docker`n`nThen click OK to continue.", "Manual Start Required", "OK", "Information")
                        } elseif ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                            Write-Host ""
                            Write-Host "    [INFO] User chose to exit" -ForegroundColor Cyan
                            Write-Host ""
                            exit 1
                        }
                        # If Yes is chosen, continue with warning
                    }
                    
                } catch {
                    Write-Host ""
                    Write-Host "    [ERROR] Failed to start remote Docker service" -ForegroundColor Red
                    Write-Host "    Error: $($_.Exception.Message)"
                    Write-Host "    Please start Docker on remote host manually"
                    Write-Host ""
                }
                
            } else {
                Write-Host ""
                Write-Host "    [SUCCESS] Remote Docker engine is running" -ForegroundColor Green
                Write-Host ""
            }
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "    [ERROR] Docker is not available on remote host" -ForegroundColor Red
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Docker is not available on the remote host.`n`nPlease install and configure Docker on Ubuntu 24.04:`n`n" +
                "sudo apt update`n" +
                "sudo apt install docker.io`n" +
                "sudo systemctl start docker`n" +
                "sudo systemctl enable docker`n`n" +
                "Optional: Add user to docker group (avoids sudo):`n" +
                "sudo usermod -aG docker `$USER`n" +
                "newgrp docker", "Remote Docker Not Available", "OK", "Error")
            exit 1
        }
    } catch {
        Write-Host ""
        Write-Host "    [ERROR] Could not check remote Docker availability" -ForegroundColor Red
        Write-Debug-Message "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Could not verify remote Docker availability.`n`nError: $($_.Exception.Message)`n`nPlease ensure the remote host is accessible and Docker is installed.", "Remote Docker Check Failed", "OK", "Error")
        exit 1
    }
    
    # Create/use a REMOTE Docker context over SSH
    # Requires SSH access to a host that already has a Docker Engine running (Ubuntu 24.04)
    # The remote host uses Unix socket: unix:///var/run/docker.sock
    Write-Host ""
    Write-Host "    [INFO] Configuring Docker context for remote Ubuntu 24.04 host..." -ForegroundColor Cyan
    Write-Host ""

    $RemoteContextName = "php_workstation"  # Name for the Docker context
    $script:RemoteContextName = $RemoteContextName  # Store globally for later use

    # Ensure we have the correct remote host for Docker context
    if ([string]::IsNullOrEmpty($remoteHost)) {
        if ($script:RemoteHostIp) {
            $remoteHost = "php-workstation@$($script:RemoteHostIp)"
            Write-Host ""
            Write-Host "    [INFO] Using remote host for Docker context: $remoteHost" -ForegroundColor Cyan
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "    [ERROR] No remote host information available for Docker context" -ForegroundColor Red
            Write-Host ""
            exit 1
        }
    }

    # Comprehensive SSH connectivity test before Docker context setup
    Write-Host "    [INFO] Performing final SSH connectivity test for Docker context..." -ForegroundColor Cyan
    $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
    
    # Create SSH config entry for reliable Docker context authentication
    Write-Host "    [INFO] Setting up SSH config for reliable Docker authentication..." -ForegroundColor Cyan
    $sshConfigPath = "$HOME\.ssh\config"
    $sshConfigDir = Split-Path $sshConfigPath -Parent
    
    # Ensure .ssh directory exists
    if (-not (Test-Path $sshConfigDir)) {
        New-Item -ItemType Directory -Path $sshConfigDir -Force | Out-Null
    }
    
    # Extract hostname and user from remoteHost
    if ($remoteHost -match "^(.+)@(.+)$") {
        $sshUser = $matches[1]
        $sshHostname = $matches[2]
    } else {
        $sshUser = "php-workstation"
        $sshHostname = $remoteHost
    }
    
    # Create SSH config entry
    $sshConfigEntry = @"

# Docker context SSH configuration for $remoteHost
Host docker-$sshHostname
    HostName $sshHostname
    User $sshUser
    IdentityFile $sshKeyPath
    IdentitiesOnly yes
    ConnectTimeout 30
    StrictHostKeyChecking no

"@
    
    # Check if config entry already exists
    $configExists = $false
    if (Test-Path $sshConfigPath) {
        $existingConfig = Get-Content $sshConfigPath -Raw
        if ($existingConfig -match "Host docker-$sshHostname") {
            $configExists = $true
            Write-Host "    [INFO] SSH config entry already exists for Docker context" -ForegroundColor Cyan
        }
    }
    
    if (-not $configExists) {
        # Append to SSH config
        Add-Content -Path $sshConfigPath -Value $sshConfigEntry
        Write-Host "    [SUCCESS] Added SSH config entry for Docker context" -ForegroundColor Green
    }
    
    # Test SSH with the exact same parameters Docker will use
    Write-Host "    [INFO] Testing SSH with key: $sshKeyPath" -ForegroundColor Cyan
    
    # Use PowerShell job with timeout for SSH and Docker test
    $sshConnectTestJob = Start-Job -ScriptBlock {
        param($sshKeyPath, $remoteHost)
        $result = & ssh -o ConnectTimeout=30 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "echo 'SSH_OK_FOR_DOCKER' && docker --version" 2>&1
        return @{
            Output = $result
            ExitCode = $LASTEXITCODE
        }
    } -ArgumentList $sshKeyPath, $remoteHost
    
    if (Wait-Job $sshConnectTestJob -Timeout 20) {
        $jobResult = Receive-Job $sshConnectTestJob
        Remove-Job $sshConnectTestJob
        $sshConnectTest = $jobResult.Output
        $sshConnectExitCode = $jobResult.ExitCode
    } else {
        Remove-Job $sshConnectTestJob -Force
        $sshConnectTest = "SSH and Docker connection test timed out after 20 seconds"
        $sshConnectExitCode = 1
    }
    
    if ($sshConnectExitCode -eq 0 -and $sshConnectTest -match "SSH_OK_FOR_DOCKER") {
        Write-Host "    [SUCCESS] SSH connectivity confirmed for Docker context" -ForegroundColor Green
        Write-Host "    SSH test output: $sshConnectTest" -ForegroundColor Green
    } else {
        Write-Host "    [ERROR] SSH connectivity failed for Docker context" -ForegroundColor Red
        Write-Host "    SSH test output: $sshConnectTest" -ForegroundColor Red
        Write-Host "    [INFO] Cannot proceed with Docker context setup due to SSH issues" -ForegroundColor Yellow
        
        [System.Windows.Forms.MessageBox]::Show(
            "SSH connectivity test failed for Docker context setup.`n`n" +
            "Error: $sshConnectTest`n`n" +
            "Please ensure:`n" +
            "1. SSH key is properly set up`n" +
            "2. Remote host is accessible`n" +
            "3. Docker is running on remote host",
            "SSH Connectivity Error",
            "OK",
            "Error"
        )
        exit 1
    }
    Write-Host ""

    # Check if the context already exists
    Write-Host "    [INFO] Checking for existing Docker context..." -ForegroundColor Cyan
    $existing = & docker context ls --format '{{.Name}}' 2>$null
    $exists = $existing -contains $RemoteContextName

    if ($exists) {
        Write-Host "    [INFO] Context '$RemoteContextName' already exists - removing to recreate with proper SSH config..." -ForegroundColor Cyan
        
        # First, switch to default context to release the remote context
        Write-Host "    [INFO] Switching to default context to release remote context..." -ForegroundColor Cyan
        & docker context use default 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Switched to default context" -ForegroundColor Green
        } else {
            Write-Host "    [WARNING] Could not switch to default context" -ForegroundColor Yellow
        }
        
        # Now try to remove the remote context
        Write-Host "    [INFO] Removing existing remote context..." -ForegroundColor Cyan
        & docker context rm $RemoteContextName 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Removed existing context" -ForegroundColor Green
            $exists = $false  # Force recreation
        } else {
            Write-Host "    [WARNING] Could not remove existing context - attempting forced removal..." -ForegroundColor Yellow
            & docker context rm --force $RemoteContextName 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    [SUCCESS] Force removed existing context" -ForegroundColor Green
                $exists = $false  # Force recreation
            } else {
                Write-Host "    [ERROR] Could not remove existing context even with force" -ForegroundColor Red
                Write-Host "    [INFO] Will attempt to create with different name..." -ForegroundColor Cyan
                $RemoteContextName = "php_workstation_new"  # Use different name as fallback
                $script:RemoteContextName = $RemoteContextName  # Update global variable
                $exists = $false
            }
        }
    }

    if (-not $exists) {
        Write-Host "    [INFO] Creating Docker context '$RemoteContextName' for ssh://$remoteHost..." -ForegroundColor Cyan
        
        # Use specific SSH key for Docker context to avoid authentication failures
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        
        # Try using SSH config host alias for better authentication
        if ($remoteHost -match "^(.+)@(.+)$") {
            $sshUser = $matches[1]
            $sshHostname = $matches[2]
            $dockerSshHost = "ssh://$sshUser@$sshHostname"
            Write-Host "    [INFO] Using SSH config alias: $sshUser@$sshHostname" -ForegroundColor Cyan
        } else {
            $dockerSshHost = "ssh://$remoteHost"
        }
        
        # Set SSH options for Docker context (persist for all Docker operations)
        $env:DOCKER_SSH_OPTS = "-i `"$sshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
        Write-Host "    [INFO] Set DOCKER_SSH_OPTS: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
        
        Write-Host "    [INFO] Creating context with host: $dockerSshHost" -ForegroundColor Cyan
        & docker context create $RemoteContextName `
            --description "Remote Docker engine over SSH (Ubuntu 24.04)" `
            --docker "host=$dockerSshHost"
            
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker context created successfully" -ForegroundColor Green
            $script:RemoteContextName = $RemoteContextName  # Update global variable
        } else {
            Write-Host "    [ERROR] Failed to create Docker context with SSH config alias" -ForegroundColor Red
            Write-Host "    [INFO] Falling back to direct SSH host..." -ForegroundColor Cyan
            
            # Fallback to direct SSH host
            $dockerSshHost = "ssh://$remoteHost"
            & docker context create $RemoteContextName `
                --description "Remote Docker engine over SSH (Ubuntu 24.04) - Direct" `
                --docker "host=$dockerSshHost"
                
            if ($LASTEXITCODE -eq 0) {
                Write-Host "    [SUCCESS] Docker context created with direct SSH" -ForegroundColor Green
                $script:RemoteContextName = $RemoteContextName  # Update global variable
            } else {
                Write-Host "    [ERROR] Failed to create Docker context" -ForegroundColor Red
            }
        }
    }
    Write-Host ""

    # Switch to the remote context
    Write-Host "    [INFO] Switching to context '$RemoteContextName'..." -ForegroundColor Cyan
    & docker context use $RemoteContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Successfully switched to remote Docker context" -ForegroundColor Green
    } else {
        Write-Host "    [WARNING] Failed to switch Docker context" -ForegroundColor Yellow
    }
    Write-Host ""

    # Test remote Docker connection
    Write-Host "    [INFO] Testing remote Docker connection with SSH key authentication..." -ForegroundColor Cyan
    Write-Host "    [INFO] Using SSH options: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
    
    # Test Docker connection via direct SSH first (more reliable than Docker context)
    Write-Host "    [INFO] Testing Docker via direct SSH connection..." -ForegroundColor Cyan
    
    # Use PowerShell job with timeout for Docker version check via SSH
    $dockerViaSshJob = Start-Job -ScriptBlock {
        param($sshKeyPath, $remoteHost)
        $result = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker version --format '{{.Server.Version}}'" 2>&1
        return @{
            Output = $result
            ExitCode = $LASTEXITCODE
        }
    } -ArgumentList $sshKeyPath, $remoteHost
    
    if (Wait-Job $dockerViaSshJob -Timeout 15) {
        $jobResult = Receive-Job $dockerViaSshJob
        Remove-Job $dockerViaSshJob
        $dockerSshResult = $jobResult.Output
        $dockerSshExitCode = $jobResult.ExitCode
    } else {
        Remove-Job $dockerViaSshJob -Force
        $dockerSshResult = "Docker SSH test timed out after 15 seconds"
        $dockerSshExitCode = 1
    }
    
    if ($dockerSshExitCode -eq 0) {
        Write-Host "    [SUCCESS] Docker accessible via direct SSH" -ForegroundColor Green
        Write-Host "    Remote Docker version: $dockerSshResult" -ForegroundColor Green
        
        # Now test with Docker context (this may still prompt for password due to Docker context limitations)
        Write-Host "    [INFO] Testing Docker context (may have limitations with SSH key auth)..." -ForegroundColor Cyan
        $dockerTestOutput = & docker --context $RemoteContextName version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Remote Docker connection test passed" -ForegroundColor Green
        Write-Host "    [INFO] Docker context is working correctly" -ForegroundColor Cyan
    } else {
        Write-Host "    [WARNING] Docker context authentication failed (this is a known limitation)" -ForegroundColor Yellow
        Write-Debug-Message "    Error details: $dockerTestOutput"
        Write-Host "" 
        Write-Host "    [INFO] Docker contexts have limitations with SSH key authentication" -ForegroundColor Cyan
        Write-Host "    [INFO] Direct SSH commands work fine, container operations will use direct SSH" -ForegroundColor Cyan
        Write-Host "    [INFO] This does not affect container functionality - continuing..." -ForegroundColor Cyan
        
        # Store that we'll need to use direct SSH for Docker operations
        $script:UseDirectSshForDocker = $true
    }
    } else {
        Write-Host "    [ERROR] Docker not accessible via SSH" -ForegroundColor Red
        Write-Host "    SSH Docker test output: $dockerSshResult" -ForegroundColor Red
        Write-Host "    [INFO] Cannot proceed without Docker access" -ForegroundColor Yellow
        
        [System.Windows.Forms.MessageBox]::Show(
            "Docker is not accessible via SSH.`n`n" +
            "Error: $dockerSshResult`n`n" +
            "Please ensure:`n" +
            "1. Docker is installed and running on remote host`n" +
            "2. User has permission to run Docker commands`n" +
            "3. SSH key authentication is working",
            "Docker SSH Access Error",
            "OK",
            "Error"
        )
        exit 1
    }
    Write-Host ""

    Write-Host "    [SUCCESS] Remote Docker environment is set up and ready to use!" -ForegroundColor Green
    Write-Host ""
    
    # Important note about Docker context SSH limitations
    if ($script:UseDirectSshForDocker) {
        Write-Host "    [INFO] Note: Docker context has SSH key authentication limitations" -ForegroundColor Cyan
        Write-Host "    [INFO] Container operations will use direct SSH commands instead" -ForegroundColor Cyan
        Write-Host "    [INFO] This provides the same functionality with better authentication" -ForegroundColor Cyan
        Write-Host ""
    }

#----------------------------------------------------#
#   STEP 4.2.1: IF LOCAL - PROMPT FOLDER SELECTION   #
#----------------------------------------------------#

} elseif ($CONTAINER_LOCATION -eq "LOCAL") {
    Write-Host ""
    Write-Host "========================================="
    Write-Host "    LOCAL FOLDER SELECTION"
    Write-Host "========================================="
    Write-Host ""
    
    Write-Host "    [INFO] Selecting local repository folder for container mounting..." -ForegroundColor Cyan
    Write-Host ""
    
    # Create folder browser dialog
    Add-Type -AssemblyName System.Windows.Forms
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog -Property @{
        Description = "Select the local folder containing your simulation model and its GitHub repository:"
        RootFolder = [System.Environment+SpecialFolder]::MyComputer
        ShowNewFolderButton = $false
    }
    
    # Set initial directory to user's Documents folder if it exists
    $documentsPath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::MyDocuments)
    if (Test-Path $documentsPath) {
        $folderBrowser.SelectedPath = $documentsPath
    }
    
    Write-Host "    [INFO] Opening folder selection dialog..." -ForegroundColor Cyan
    Write-Host ""
    $folderResult = $folderBrowser.ShowDialog()
    
    if ($folderResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedPath = $folderBrowser.SelectedPath
        Write-Host "    [INFO] Selected local folder: $selectedPath" -ForegroundColor Cyan
        Write-Host ""
        
        # Validate that a folder was actually selected
        if ([string]::IsNullOrWhiteSpace($selectedPath) -or -not (Test-Path $selectedPath)) {
            Write-Host "    [ERROR] Invalid folder selection" -ForegroundColor Red
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Please select a valid folder containing your repository.", "Invalid Selection", "OK", "Error")
            exit 1
        }
        
        # Store the full local path
        $script:LocalRepoPath = $selectedPath
        
        # Extract the repository name (last folder in the path)
        $script:SelectedRepo = Split-Path $selectedPath -Leaf
        
        Write-Host "    [SUCCESS] Local repository path: $($script:LocalRepoPath)" -ForegroundColor Green
        Write-Host "    [SUCCESS] Repository name: $($script:SelectedRepo)" -ForegroundColor Green
        Write-Host ""
        
        # Check if the selected folder contains a Git repository
        $gitPath = Join-Path $selectedPath ".git"
        if (Test-Path $gitPath) {
            Write-Host "    [SUCCESS] Git repository detected in selected folder" -ForegroundColor Green
        } else {
            Write-Host "    [WARNING] No .git directory found in selected folder" -ForegroundColor Yellow
            Write-Host "    This folder may not be a Git repository"
            Write-Host ""
            
            # Ask user if they want to continue
            $continueResult = [System.Windows.Forms.MessageBox]::Show(
                "The selected folder does not appear to be a Git repository.`n`nDo you want to continue anyway?",
                "No Git Repository Found",
                "YesNo",
                "Question"
            )
            
            if ($continueResult -eq [System.Windows.Forms.DialogResult]::No) {
                Write-Host "    [INFO] User chose not to continue without Git repository" -ForegroundColor Cyan
                Write-Host ""
                exit 1
            } else {
                Write-Host "    [INFO] User chose to continue without Git repository" -ForegroundColor Cyan
                Write-Host ""
            }
        }
        
    } else {
        Write-Host "    [ERROR] User cancelled folder selection" -ForegroundColor Red
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Folder selection is required to continue.", "Selection Cancelled", "OK", "Warning")
        exit 1
    }

#--------------------------------------------------#
#   STEP 4.2.2: IF LOCAL - DOCKER CONTEXT LOGIC    #
#--------------------------------------------------#

    Write-Host ""
    Write-Host "========================================="
    Write-Host "    LOCAL DOCKER CONTEXT SETUP"
    Write-Host "========================================="
    Write-Host ""
    
    Write-Host "    [INFO] Setting up Docker context for local execution..." -ForegroundColor Cyan
    Write-Host "    Selected repository: $($script:SelectedRepo)"
    Write-Host "    Local repository path: $($script:LocalRepoPath)"
    Write-Host ""
    
    # Verify Docker is available locally
    Write-Host "    [INFO] Checking local Docker availability..." -ForegroundColor Cyan
    Write-Host ""
    try {
        $dockerVersion = & docker --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker is available locally" -ForegroundColor Green
            Write-Host "    Docker version: $dockerVersion"
            Write-Host ""
            
            # Ensure Docker engine is running
            Write-Host "    [INFO] Checking Docker engine status..." -ForegroundColor Cyan
            
            # First try a quick version check which is less likely to hang
            try {
                $quickCheck = & docker version --format "{{.Server.Version}}" 2>$null
                if ($LASTEXITCODE -eq 0 -and $quickCheck) {
                    Write-Host "    [SUCCESS] Docker engine is running (Server version: $quickCheck)" -ForegroundColor Green
                    $dockerRunning = $true
                } else {
                    $dockerRunning = $false
                }
            } catch {
                $dockerRunning = $false
            }
            
            # If quick check failed, try docker info with timeout
            if (-not $dockerRunning) {
                Write-Host "    [INFO] Quick check failed, trying detailed status check..." -ForegroundColor Cyan
                
                # Use a timeout for docker info to prevent hanging
                $dockerInfoJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
                $dockerInfoResult = Wait-Job $dockerInfoJob -Timeout 10
                
                if ($dockerInfoResult) {
                    $exitCode = Receive-Job $dockerInfoJob
                    Remove-Job $dockerInfoJob
                    $dockerRunning = ($exitCode -eq 0)
                } else {
                    Write-Host "    [WARNING] Docker info command timed out (Docker may be starting)" -ForegroundColor Yellow
                    Stop-Job $dockerInfoJob -ErrorAction SilentlyContinue
                    Remove-Job $dockerInfoJob -ErrorAction SilentlyContinue
                    $dockerRunning = $false
                }
            }
            
            if (-not $dockerRunning) {
                Write-Host "    [WARNING] Docker engine is not running" -ForegroundColor Yellow
                Write-Host "    Attempting to start Docker Desktop..."
                Write-Host ""
                
                try {
                    # Method 1: Try to start Docker Desktop application directly
                    $dockerDesktopPath = "${env:ProgramFiles}\Docker\Docker\Docker Desktop.exe"
                    if (Test-Path $dockerDesktopPath) {
                        Write-Host "    Starting Docker Desktop application..."
                        Start-Process -FilePath $dockerDesktopPath -WindowStyle Hidden
                    } else {
                        # Fallback: Try alternative path
                        $dockerDesktopAlt = "${env:LOCALAPPDATA}\Programs\Docker\Docker\Docker Desktop.exe"
                        if (Test-Path $dockerDesktopAlt) {
                            Write-Host "    Starting Docker Desktop application (alternative path)..."
                            Start-Process -FilePath $dockerDesktopAlt -WindowStyle Hidden
                        } else {
                            Write-Host "    [WARNING] Docker Desktop executable not found in standard locations" -ForegroundColor Yellow
                            Write-Host "    Trying service startup as fallback..."
                            Start-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
                        }
                    }
                    
                    # Wait for Docker daemon to start with progress indication
                    Write-Host "    Waiting for Docker daemon to initialize..."
                    $maxAttempts = 30  # 30 seconds max wait
                    $attempt = 0
                    
                    do {
                        Start-Sleep -Seconds 1
                        $attempt++
                        Write-Host "    Checking Docker daemon status... ($attempt/$maxAttempts)" -NoNewline
                        
                        # Use timeout for docker info to prevent hanging
                        $checkJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
                        $checkResult = Wait-Job $checkJob -Timeout 5
                        
                        if ($checkResult) {
                            $checkExitCode = Receive-Job $checkJob
                            Remove-Job $checkJob
                            
                            if ($checkExitCode -eq 0) {
                                Write-Host " [SUCCESS]" -ForegroundColor Green
                                break
                            } else {
                                Write-Host ""
                            }
                        } else {
                            Write-Host " [TIMEOUT]"
                            Stop-Job $checkJob -ErrorAction SilentlyContinue
                            Remove-Job $checkJob -ErrorAction SilentlyContinue
                        }
                        
                        # Show different messages at different intervals
                        if ($attempt -eq 10) {
                            Write-Host "    [INFO] Docker is still starting up (this may take a moment)..." -ForegroundColor Cyan
                        } elseif ($attempt -eq 20) {
                            Write-Host "    [INFO] Still waiting for Docker daemon (almost ready)..." -ForegroundColor Cyan
                        }
                        
                    } while ($attempt -lt $maxAttempts)
                    
                    # Final check with timeout
                    $finalJob = Start-Job -ScriptBlock { & docker info 2>&1 | Out-Null; $LASTEXITCODE }
                    $finalResult = Wait-Job $finalJob -Timeout 5
                    
                    if ($finalResult) {
                        $finalExitCode = Receive-Job $finalJob
                        Remove-Job $finalJob
                    } else {
                        Write-Host "    [WARNING] Final Docker check timed out" -ForegroundColor Yellow
                        Stop-Job $finalJob -ErrorAction SilentlyContinue
                        Remove-Job $finalJob -ErrorAction SilentlyContinue
                        $finalExitCode = 1
                    }
                    
                    if ($finalExitCode -eq 0) {
                        Write-Host "    [SUCCESS] Docker engine started successfully!" -ForegroundColor Green
                        Write-Host "    Startup time: $attempt seconds"
                    } else {
                        Write-Host "    [WARNING] Docker engine did not start within $maxAttempts seconds" -ForegroundColor Yellow
                        Write-Host "    Please check Docker Desktop manually"
                        Write-Host ""
                        
                        # Offer user choice to continue or exit
                        $choice = [System.Windows.Forms.MessageBox]::Show(
                            "Docker engine could not be started automatically.`n`nWould you like to:`n- Click 'Yes' to wait and try again`n- Click 'No' to continue anyway (may cause errors)`n- Click 'Cancel' to exit",
                            "Docker Startup Issue",
                            "YesNoCancel",
                            "Warning"
                        )
                        
                        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
                            Write-Host "    [INFO] Please start Docker Desktop manually and click OK when ready" -ForegroundColor Cyan
                            $manualStartChoice = [System.Windows.Forms.MessageBox]::Show(
                                "Please start Docker Desktop manually and wait for it to be ready, then click OK to continue.`n`nOr click Cancel to skip Docker checks and continue anyway.",
                                "Manual Start Required", 
                                "OKCancel", 
                                "Information"
                            )
                            
                            if ($manualStartChoice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                                Write-Host "    [INFO] User chose to skip Docker checks and continue" -ForegroundColor Yellow
                            }
                        } elseif ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                            Write-Host "    [INFO] User chose to exit" -ForegroundColor Cyan
                            exit 1
                        }
                        # If No is chosen, continue with warning
                    }
                    
                } catch {
                    Write-Host "    [ERROR] Failed to start Docker Desktop" -ForegroundColor Red
                    Write-Host "    Error: $($_.Exception.Message)"
                    Write-Host "    Please start Docker Desktop manually"
                }
                
            } else {
                Write-Host "    [SUCCESS] Docker engine is running" -ForegroundColor Green
            }
            Write-Host ""
        } else {
            Write-Host "    [ERROR] Docker is not available locally" -ForegroundColor Red
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Docker is not available on this system.`n`nPlease ensure Docker Desktop is installed and running.", "Docker Not Available", "OK", "Error")
            exit 1
        }
    } catch {
        Write-Host "    [ERROR] Could not check Docker availability" -ForegroundColor Red
        Write-Debug-Message "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Could not verify Docker availability.`n`nPlease ensure Docker Desktop is installed and running.", "Docker Check Failed", "OK", "Error")
        exit 1
    }
    
    Write-Host "    [INFO] Setting up local Docker context..." -ForegroundColor Cyan
    Write-Host ""

    # Create/use a LOCAL Docker context
    # Creates a context named "local" pointing at the local Docker engine socket
    # Detects OS and picks the right socket (npipe on Windows, unix socket elsewhere)
    Write-Host "    Detecting platform and configuring Docker context..."

    $LocalContextName = "local" 

    # Pick the correct local socket for the platform
    $onWindows = $false
    if ($PSVersionTable.PSEdition -eq "Desktop" -or $env:OS -like "*Windows*") {
        $onWindows = $true
    }

    if ($onWindows) {
        $dockerHost = "npipe:////./pipe/docker_engine"
        Write-Host "    Platform: Windows - Using named pipe"
    } else {
        # Linux & macOS
        $dockerHost = "unix:///var/run/docker.sock"
        Write-Host "    Platform: Unix/Linux - Using Unix socket"
    }
    Write-Host ""

    # Check if the context already exists
    Write-Host "    [INFO] Checking for existing Docker context..." -ForegroundColor Cyan
    $exists = (& docker context ls --format '{{.Name}}' 2>$null) -contains $LocalContextName

    if (-not $exists) {
        Write-Host "    [INFO] Creating Docker context '$LocalContextName' for $dockerHost..." -ForegroundColor Cyan
        & docker context create $LocalContextName --description "Local Docker engine" --docker "host=$dockerHost"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker context created successfully" -ForegroundColor Green
        } else {
            Write-Host "    [ERROR] Failed to create Docker context" -ForegroundColor Red
        }
    } else {
        Write-Host "    [INFO] Context '$LocalContextName' already exists" -ForegroundColor Cyan
    }
    Write-Host ""

    # Switch to the local context
    Write-Host "    [INFO] Switching to context '$LocalContextName'..." -ForegroundColor Cyan
    & docker context use $LocalContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Successfully switched to local Docker context" -ForegroundColor Green
    } else {
        Write-Host "    [WARNING] Failed to switch Docker context" -ForegroundColor Yellow
    }
    Write-Host ""

    # Quick smoke test
    Write-Host "    [INFO] Testing Docker connection..." -ForegroundColor Cyan
    & docker --context $LocalContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Docker connection test passed" -ForegroundColor Green
    } else {
        Write-Host "    [WARNING] Docker connection test failed" -ForegroundColor Yellow
    }
    Write-Host ""

    Write-Host "    [SUCCESS] Local Docker environment is set up and ready to use!" -ForegroundColor Green
    Write-Host ""

} else {
    Write-Host ""
    Write-Host "    [ERROR] Invalid container location state" -ForegroundColor Red
    Write-Host "    Please restart the application and select a valid option"
    Write-Host ""
    exit 1
}

#--------------------------------------------------------#
#   STEP 5: PROMPT FOR STARTING AND STOPPING CONTAINER   #
#--------------------------------------------------------#

#---------------------#
#  HELPER FUNCTIONS:  #
#---------------------#

# 0: Helper function to set up SSH environment for remote Docker operations
function Set-DockerSSHEnvironment {
    Write-Debug-Message "[DEBUG] Setting up Docker SSH environment..."
    if ($CONTAINER_LOCATION -like "REMOTE@*" -and (-not $env:DOCKER_SSH_OPTS -or [string]::IsNullOrEmpty($env:DOCKER_SSH_OPTS))) {
        Write-Debug-Message "[DEBUG] Remote container detected, SSH environment needs setup"
        if ($script:SshKeyPath) {
            $env:DOCKER_SSH_OPTS = "-i `"$script:SshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
            Write-Debug-Message "[DEBUG] SSH environment restored from cached key path: $script:SshKeyPath"
            Write-Host "[INFO] Restored SSH environment for Docker operations: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
        } else {
            # Fallback - reconstruct from USERNAME
            $script:SshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
            $env:DOCKER_SSH_OPTS = "-i `"$script:SshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
            Write-Debug-Message "[DEBUG] SSH environment reconstructed from USERNAME: $USERNAME"
            Write-Debug-Message "[DEBUG] Reconstructed key path: $script:SshKeyPath"
            Write-Host "[INFO] Reconstructed SSH environment for Docker operations: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
        }
    } else {
        Write-Debug-Message "[DEBUG] SSH environment already configured or not needed (local container)"
    }
}

# 0.5: Helper function to verify SSH key files exist on remote system for Docker mounting
function Test-RemoteSSHKeyFiles {
    param(
        [string]$RemoteHost,
        [string]$Username
    )
    
    Write-Debug-Message "[DEBUG] Testing remote SSH key files for user: $Username on host: $RemoteHost"
    
    $remoteSSHKeyPath = "/home/php-workstation/.ssh/id_ed25519_${Username}"
    $remoteKnownHostsPath = "/home/php-workstation/.ssh/known_hosts"
    $localSSHKeyPath = "$HOME\.ssh\id_ed25519_$Username"
    
    Write-Debug-Message "[DEBUG] Remote private key path: $remoteSSHKeyPath"
    Write-Debug-Message "[DEBUG] Remote known_hosts path: $remoteKnownHostsPath"
    Write-Debug-Message "[DEBUG] Local SSH key path: $localSSHKeyPath"
    
    $results = @{
        PrivateKeyExists = $false
        KnownHostsExists = $false
        ErrorDetails = @()
    }
    
    try {
        Write-Debug-Message "[DEBUG] Starting remote SSH key file verification..."
        
        # Check if private key exists on remote with timeout protection
        $checkPrivateKeyCommand = "test -f '$remoteSSHKeyPath' && echo PRIVATE_KEY_EXISTS || echo PRIVATE_KEY_MISSING"
        Write-Debug-Message "[DEBUG] Private key check command: $checkPrivateKeyCommand"
        
        # Use PowerShell job with timeout for SSH private key check
        Write-Debug-Message "[DEBUG] Starting private key check job..."
        $privateKeyJob = Start-Job -ScriptBlock {
            param($localSSHKeyPath, $RemoteHost, $checkPrivateKeyCommand)
            & ssh -i $localSSHKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $RemoteHost $checkPrivateKeyCommand 2>&1
        } -ArgumentList $localSSHKeyPath, $RemoteHost, $checkPrivateKeyCommand
        
        if (Wait-Job $privateKeyJob -Timeout 15) {
            $privateKeyCheckResult = Receive-Job $privateKeyJob
            Remove-Job $privateKeyJob
            Write-Debug-Message "[DEBUG] Private key check result: $privateKeyCheckResult"
            
            if ($privateKeyCheckResult -match "PRIVATE_KEY_EXISTS") {
                $results.PrivateKeyExists = $true
                Write-Debug-Message "[DEBUG] Private key found on remote system"
            } else {
                Write-Debug-Message "[DEBUG] Private key not found on remote system"
                $results.ErrorDetails += "Private key not found at: $remoteSSHKeyPath (Result: $privateKeyCheckResult)"
            }
        } else {
            Write-Debug-Message "[DEBUG] Private key check timed out"
            Remove-Job $privateKeyJob -Force
            $results.ErrorDetails += "Private key check timed out after 15 seconds"
        }
        
        # Check if known_hosts exists on remote with timeout protection
        $checkKnownHostsCommand = "test -f '$remoteKnownHostsPath' && echo KNOWN_HOSTS_EXISTS || echo KNOWN_HOSTS_MISSING"
        Write-Debug-Message "[DEBUG] Known_hosts check command: $checkKnownHostsCommand"
        
        # Use PowerShell job with timeout for SSH known_hosts check
        Write-Debug-Message "[DEBUG] Starting known_hosts check job..."
        $knownHostsJob = Start-Job -ScriptBlock {
            param($localSSHKeyPath, $RemoteHost, $checkKnownHostsCommand)
            & ssh -i $localSSHKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $RemoteHost $checkKnownHostsCommand 2>&1
        } -ArgumentList $localSSHKeyPath, $RemoteHost, $checkKnownHostsCommand
        
        if (Wait-Job $knownHostsJob -Timeout 15) {
            $knownHostsCheckResult = Receive-Job $knownHostsJob
            Remove-Job $knownHostsJob
            Write-Debug-Message "[DEBUG] Known_hosts check result: $knownHostsCheckResult"
            
            if ($knownHostsCheckResult -match "KNOWN_HOSTS_EXISTS") {
                $results.KnownHostsExists = $true
                Write-Debug-Message "[DEBUG] Known_hosts file found on remote system"
            } else {
                Write-Debug-Message "[DEBUG] Known_hosts file not found on remote system"
                $results.ErrorDetails += "Known_hosts file not found at: $remoteKnownHostsPath (Result: $knownHostsCheckResult)"
            }
        } else {
            Write-Debug-Message "[DEBUG] Known_hosts check timed out"
            Remove-Job $knownHostsJob -Force
            $results.ErrorDetails += "Known_hosts check timed out after 15 seconds"
        }
        
    } catch {
        Write-Debug-Message "[DEBUG] SSH key file verification failed with exception: $($_.Exception.Message)"
        $results.ErrorDetails += "SSH connection failed: $($_.Exception.Message)"
    }
    
    Write-Debug-Message "[DEBUG] SSH key file verification completed"
    Write-Debug-Message "[DEBUG] Private key exists: $($results.PrivateKeyExists)"
    Write-Debug-Message "[DEBUG] Known_hosts exists: $($results.KnownHostsExists)"
    Write-Debug-Message "[DEBUG] Error count: $($results.ErrorDetails.Count)"
    
    return $results
}

# 1: Helper function to extract and construct potential paths from the YAML file
function Get-YamlPathValue {
    param (
        [string]$YamlPath,
        [string]$Key,
        [string]$BaseDir # Pass ProjectRoot here (already uses forward slashes)
    )
    
    Write-Debug-Message "[DEBUG] Resolving YAML key '$Key' from path '$YamlPath' (BaseDir: $BaseDir, Location: $CONTAINER_LOCATION)"
    
    # Handle remote vs local YAML file reading
    if ($CONTAINER_LOCATION -like "REMOTE@*") {
        # For remote operations, use SSH to read the YAML file
        Set-DockerSSHEnvironment
        $remoteHost = "php-workstation@$($script:RemoteHostIp)"
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        
        Write-Host "[INFO] Reading remote YAML file: $YamlPath" -ForegroundColor Cyan
        Write-Debug-Message "[DEBUG] Remote host: $remoteHost, SSH key: $sshKeyPath"
        
        # Use PowerShell job with timeout for YAML file reading
        $yamlReadJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost, $YamlPath)
            & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cat '$YamlPath'" 2>$null
        } -ArgumentList $sshKeyPath, $remoteHost, $YamlPath
        
        if (Wait-Job $yamlReadJob -Timeout 15) {
            $yamlContent = Receive-Job $yamlReadJob
            Remove-Job $yamlReadJob
            Write-Debug-Message "[DEBUG] Retrieved remote YAML content for '$Key' (length: $($yamlContent.Length))"
        } else {
            Remove-Job $yamlReadJob -Force
            Write-Host "Warning: YAML file reading timed out after 15 seconds" 
            $yamlContent = $null
            $LASTEXITCODE = 1
            Write-Debug-Message "[DEBUG] YAML remote read job timed out for path '$YamlPath'"
        }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: Could not read remote YAML file: $YamlPath"
            Write-Debug-Message "[DEBUG] Unable to read remote YAML file '$YamlPath'; returning null"
            return $null
        }
        
        # Find the line with the key
        $line = $yamlContent -split "`n" | Where-Object { $_ -match "^$Key\s*:" } | Select-Object -First 1
    } else {
        # For local operations, use Select-String as before
        if (-not (Test-Path $YamlPath)) {
            Write-Host "Warning: Local YAML file not found: $YamlPath"
            Write-Debug-Message "[DEBUG] Local YAML file '$YamlPath' not found on disk"
            return $null
        }
        $lineObj = Select-String -Path $YamlPath -Pattern "^$Key\s*:" | Select-Object -First 1
        $line = $lineObj.Line
    }
    
    if ($line) {
        $value = ($line -split ":\s*", 2)[1].Split("#")[0].Trim()
        $constructedPath = $null

        # Check if the path from YAML is absolute (Windows or Unix-like)
        if ([System.IO.Path]::IsPathRooted($value) -or $value.StartsWith('/')) {
            $constructedPath = $value
            Write-Host "Path '$value' for key '$Key' is absolute."
            Write-Debug-Message "[DEBUG] YAML value for '$Key' is absolute: $constructedPath"
        } else {
            # Construct path relative to the specified BaseDir (ProjectRoot)
            # Ensure BaseDir and value use consistent slashes for joining
            $valueNormalized = $value -replace '\\', '/'
            $valueNormalized = $valueNormalized -replace '\.', '' # Remove leading dot if present
            $constructedPath = "$BaseDir/$valueNormalized" # Simple string concatenation with forward slashes
            # Clean up potential double slashes, except after protocol like C://
            $constructedPath = $constructedPath -replace '(?<!:)/{2,}', '/'
            Write-Host "Path '$value' for key '$Key' is relative. Constructed as '$constructedPath'."
            Write-Debug-Message "[DEBUG] YAML value for '$Key' resolved relative to BaseDir: $constructedPath"
        }

        # Normalize to forward slashes for consistency before returning
        $normalizedPath = $constructedPath -replace '\\', '/'
        Write-Debug-Message "[DEBUG] Returning normalized YAML path for '$Key': $normalizedPath"
        return $normalizedPath
    }
    Write-Host "Warning: No matching line found for key: $Key in '$YamlPath'"
    Write-Debug-Message "[DEBUG] No matching YAML key '$Key' found in '$YamlPath'"
    return $null
}

# 2: Helper function to check and create directory
function Test-AndCreateDirectory {
    param(
        [string]$Path,
        [string]$PathKey # For logging purposes (e.g., "output_dir")
    )
    Write-Debug-Message "[DEBUG] Validating path '$Path' for key '$PathKey' (Location: $CONTAINER_LOCATION)"
    if (-not $Path) {
        Write-Host "Error: Could not determine $PathKey path from YAML."
        Write-Debug-Message "[DEBUG] Path resolution for '$PathKey' failed because value is null or empty"
        return $false
    }

    if ($CONTAINER_LOCATION -like "REMOTE@*") {
        # For remote operations, use SSH to check and create directories
        Set-DockerSSHEnvironment
        $remoteHost = "php-workstation@$($script:RemoteHostIp)"
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        
        # Use Unix path format for remote operations (no conversion needed)
        $remotePath = $Path
        
        Write-Host "[INFO] Checking remote directory ($PathKey): $remotePath" -ForegroundColor Cyan
        Write-Debug-Message "[DEBUG] SSH command: ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost"
        
        # Use PowerShell job with timeout for directory check
        $dirCheckJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost, $remotePath)
            & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "test -d '$remotePath' && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1
        } -ArgumentList $sshKeyPath, $remoteHost, $remotePath
        
        if (Wait-Job $dirCheckJob -Timeout 15) {
            $dirCheck = Receive-Job $dirCheckJob
            Remove-Job $dirCheckJob
        } else {
            Remove-Job $dirCheckJob -Force
            Write-Host "[ERROR] Directory check timed out after 15 seconds for: $remotePath" -ForegroundColor Red
            return $false
        }
        Write-Debug-Message "[DEBUG] Directory check result: $dirCheck"
        
        if ($dirCheck -match "NOT_EXISTS") {
            Write-Host "[WARNING] Remote $PathKey path not found: $remotePath. Creating directory..." -ForegroundColor Yellow
            
            # Use PowerShell job with timeout for directory creation
            $createJob = Start-Job -ScriptBlock {
                param($sshKeyPath, $remoteHost, $remotePath)
                & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "mkdir -p '$remotePath' && echo 'CREATED' || echo 'FAILED'" 2>&1
            } -ArgumentList $sshKeyPath, $remoteHost, $remotePath
            
            if (Wait-Job $createJob -Timeout 15) {
                $createResult = Receive-Job $createJob
                Remove-Job $createJob
            } else {
                Remove-Job $createJob -Force
                Write-Host "[ERROR] Directory creation timed out after 15 seconds for: $remotePath" -ForegroundColor Red
                return $false
            }
            Write-Debug-Message "[DEBUG] Create result: $createResult"
            
            if ($createResult -match "CREATED") {
                Write-Host "[SUCCESS] Successfully created remote $PathKey directory: $remotePath" -ForegroundColor Green
                return $true
            } else {
                Write-Host "[ERROR] Failed to create remote $PathKey directory: $remotePath" -ForegroundColor Red
                Write-Debug-Message "[ERROR] Create error details: $createResult"
                return $false
            }
        } elseif ($dirCheck -match "EXISTS") {
            # Check if it's actually a directory, not a file
            # Use PowerShell job with timeout for directory type check
            $isDirCheckJob = Start-Job -ScriptBlock {
                param($sshKeyPath, $remoteHost, $remotePath)
                & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "test -d '$remotePath' && echo 'DIR' || echo 'FILE'" 2>&1
            } -ArgumentList $sshKeyPath, $remoteHost, $remotePath
            
            if (Wait-Job $isDirCheckJob -Timeout 15) {
                $isDirCheck = Receive-Job $isDirCheckJob
                Remove-Job $isDirCheckJob
            } else {
                Remove-Job $isDirCheckJob -Force
                Write-Host "[ERROR] Directory type check timed out after 15 seconds for: $remotePath" -ForegroundColor Red
                return $false
            }
            Write-Debug-Message "[DEBUG] Directory type check result: $isDirCheck"
            
            if ($isDirCheck -match "FILE") {
                Write-Host "[ERROR] The remote path specified for $PathKey exists but is a file, not a directory: $remotePath" -ForegroundColor Red
                return $false
            } else {
                Write-Host "[SUCCESS] Remote $PathKey directory exists: $remotePath" -ForegroundColor Green
                return $true
            }
        } else {
            Write-Host "[ERROR] Could not check remote $PathKey directory: $remotePath" -ForegroundColor Red
            Write-Debug-Message "[ERROR] SSH check error details: $dirCheck"
            return $false
        }
    } else {
        # Local operations - use existing logic
        # Use native path format for Test-Path and New-Item
        $NativePath = $Path -replace '/', '\\'
        Write-Debug-Message "[DEBUG] Evaluating local path '$NativePath' for key '$PathKey'"

        if (-not (Test-Path $NativePath)) {
            Write-Host "Warning: $PathKey path not found: $NativePath. Creating directory..."
            try {
                New-Item -ItemType Directory -Path $NativePath -Force -ErrorAction Stop | Out-Null
                Write-Host "Successfully created $PathKey directory: $NativePath"
                Write-Debug-Message "[DEBUG] Created local directory '$NativePath' for key '$PathKey'"
                return $true
            } catch {
                Write-Host "Error: Failed to create $PathKey directory: $NativePath - $($_.Exception.Message)"
                Write-Debug-Message "[DEBUG] Failed to create local directory '$NativePath': $($_.Exception.Message)"
                # Attempt to resolve the path to see if it exists now, maybe a race condition or delay
                if(Test-Path $NativePath) {
                     Write-Host "Info: Directory $NativePath seems to exist now despite previous error."
                     Write-Debug-Message "[DEBUG] Directory '$NativePath' detected after creation error"
                     return $true
                }
                return $false
            }
        } elseif (-not (Get-Item $NativePath).PSIsContainer) {
            Write-Host "Error: The path specified for $PathKey exists but is a file, not a directory: $NativePath"
            Write-Debug-Message "[DEBUG] Path '$NativePath' for key '$PathKey' exists but is not a directory"
            return $false
        } else {
             # Directory exists
             Write-Debug-Message "[DEBUG] Local directory '$NativePath' already exists"
             return $true
        }
    }
}

# 3: Helper function to convert Windows path to Docker Desktop/WSL format
function Convert-PathToDockerFormat {
    param([string]$Path)
    Write-Debug-Message "[DEBUG] Converting path to Docker format: $Path"
    # Input example: P:/My_Models/IMPACTncd_Japan
    # Match drive letter (e.g., P) and the rest of the path
    if ($Path -match '^([A-Za-z]):/(.*)') {
        $driveLetter = $matches[1].ToLower()
        $restOfPath = $matches[2]
        # Construct the Docker path: /<drive_letter>/<rest_of_path>
        $dockerPath = "/$driveLetter/$restOfPath"
        # Remove trailing slash if present
        $dockerPath = $dockerPath -replace '/$', ''
        Write-Debug-Message "[DEBUG] Docker-formatted path: $dockerPath"
        return $dockerPath
    } else {
        Write-Warning "Path '$Path' did not match expected Windows format (e.g., C:/path/to/dir)"
        Write-Debug-Message "[DEBUG] Path '$Path' unchanged during Docker conversion"
        return $Path # Return original path if format is unexpected
    }
}

# 4: Helper function to capture git repository state
function Get-GitRepositoryState {
    param(
        [string]$RepoPath,
        [switch]$Pull
    )
    
    Write-Debug-Message "[DEBUG] Capturing git repository state for '$RepoPath' (Pull: $Pull, Location: $CONTAINER_LOCATION)"
    
    if ($CONTAINER_LOCATION -like "REMOTE@*") {
        # Handle remote repository paths
        if (-not $RepoPath) {
            Write-Host "[WARNING] No remote repository path provided" -ForegroundColor Yellow
            Write-Debug-Message "[DEBUG] Remote repository state capture aborted: RepoPath was null or empty"
            return $null
        }
        
        try {
            Set-DockerSSHEnvironment
            $remoteHost = "php-workstation@$($script:RemoteHostIp)"
            $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
            
            Write-Debug-Message "[DEBUG] Remote git state query target: Host=$remoteHost, Key=$sshKeyPath"
            
            Write-Host "[INFO] Checking remote git repository state: $RepoPath" -ForegroundColor Cyan
            
            # Check if this is a git repository
            $isGitRepo = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git rev-parse --is-inside-work-tree" 2>$null
            Write-Debug-Message "[DEBUG] Remote git repo check result: $isGitRepo (ExitCode: $LASTEXITCODE)"
            if ($LASTEXITCODE -ne 0 -or $isGitRepo -ne "true") {
                Write-Host "[INFO] Remote path is not a git repository or git not available" -ForegroundColor Cyan
                return $null
            }
            
            if($Pull) {
                # Pull latest changes for safety
                Write-Host "[INFO] Pulling latest changes to remote repository for safety..." -ForegroundColor Cyan
                & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git pull" 2>$null
                
                Write-Host "[INFO] Waiting for git operations to complete... 3 seconds" -ForegroundColor Cyan
                Start-Sleep -Seconds 1 # Small delay to ensure git operations complete
                Write-Host "[INFO] Waiting for git operations to complete... 2 seconds" -ForegroundColor Cyan
                Start-Sleep -Seconds 1 # Small delay to ensure git operations complete
                Write-Host "[INFO] Waiting for git operations to complete... 1 seconds" -ForegroundColor Cyan
                Start-Sleep -Seconds 1 # Small delay to ensure git operations complete
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[SUCCESS] Successfully pulled latest changes" -ForegroundColor Green
                    Write-Debug-Message "[DEBUG] Remote git pull completed successfully for '$RepoPath'"
                } else {
                    Write-Host "[WARNING] Git pull failed or no changes to pull" -ForegroundColor Yellow
                    Write-Debug-Message "[DEBUG] Remote git pull failed or no changes for '$RepoPath' (ExitCode: $LASTEXITCODE)"
                }
            }

            # Get current commit hash
            $currentCommit = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git rev-parse HEAD" 2>$null
            Write-Debug-Message "[DEBUG] Remote git commit hash: $currentCommit"
            
            # Get list of modified/added/deleted files
            $gitStatus = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git status --porcelain" 2>$null
            
            # Get list of untracked files
            $untrackedFiles = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git ls-files --others --exclude-standard" 2>$null
            
            $state = @{
                RepoPath = $RepoPath
                CurrentCommit = $currentCommit
                ModifiedFiles = ($gitStatus -split "`n" | Where-Object { $_.Trim() -ne "" })
                UntrackedFiles = ($untrackedFiles -split "`n" | Where-Object { $_.Trim() -ne "" })
                Timestamp = Get-Date
                IsRemote = $true
            }
            
            Write-Host "[SUCCESS] Remote git repository state captured" -ForegroundColor Green
            Write-Debug-Message "[DEBUG] Remote git state summary -> Modified: $($state.ModifiedFiles.Count), Untracked: $($state.UntrackedFiles.Count)"
            return $state
            
        } catch {
            Write-Host "[WARNING] Error capturing remote git repository state: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Debug-Message "[DEBUG] Exception during remote git state capture: $($_.Exception.Message)"
            return $null
        }
    } else {
        # Handle local repository paths
        if (-not (Test-Path $RepoPath)) {
            Write-Host "[WARNING] Repository path does not exist: $RepoPath" -ForegroundColor Yellow
            Write-Debug-Message "[DEBUG] Local repository path '$RepoPath' not found"
            return $null
        }
        
        try {
            Push-Location $RepoPath
            Write-Debug-Message "[DEBUG] Working directory switched to '$RepoPath'"
            
            # Check if this is a git repository
            $isGitRepo = git rev-parse --is-inside-work-tree 2>$null
            Write-Debug-Message "[DEBUG] Local git repo check result: $isGitRepo (ExitCode: $LASTEXITCODE)"
            if ($LASTEXITCODE -ne 0 -or $isGitRepo -ne "true") {
                Write-Host "[INFO] Not a git repository or git not available" -ForegroundColor Cyan
                return $null
            }
            
            if($Pull) {
                # Pull latest changes for safety
                Write-Host "[INFO] Pulling latest changes to local repository for safety..." -ForegroundColor Cyan
                git pull 2>$null
                
                Write-Host "[INFO] Waiting for git operations to complete... 3 seconds" -ForegroundColor Cyan
                Start-Sleep -Seconds 1 # Small delay to ensure git operations complete
                Write-Host "[INFO] Waiting for git operations to complete... 2 seconds" -ForegroundColor Cyan
                Start-Sleep -Seconds 1 # Small delay to ensure git operations complete
                Write-Host "[INFO] Waiting for git operations to complete... 1 seconds" -ForegroundColor Cyan
                Start-Sleep -Seconds 1 # Small delay to ensure git operations complete

                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[SUCCESS] Successfully pulled latest changes" -ForegroundColor Green
                    Write-Debug-Message "[DEBUG] Local git pull completed successfully for '$RepoPath'"
                } else {
                    Write-Host "[WARNING] Git pull failed or no changes to pull" -ForegroundColor Yellow
                    Write-Debug-Message "[DEBUG] Local git pull failed or no changes for '$RepoPath' (ExitCode: $LASTEXITCODE)"
                }
            }
            
            # Get current commit hash
            $currentCommit = git rev-parse HEAD 2>$null
            Write-Debug-Message "[DEBUG] Local git commit hash: $currentCommit"
            
            # Get list of modified/added/deleted files
            $gitStatus = git status --porcelain 2>$null
            
            # Get list of untracked files
            $untrackedFiles = git ls-files --others --exclude-standard 2>$null
            
            $state = @{
                RepoPath = $RepoPath
                CurrentCommit = $currentCommit
                ModifiedFiles = ($gitStatus -split "`n" | Where-Object { $_.Trim() -ne "" })
                UntrackedFiles = ($untrackedFiles -split "`n" | Where-Object { $_.Trim() -ne "" })
                Timestamp = Get-Date
                IsRemote = $false
            }
            
            Write-Host "[INFO] Captured local git state: $($state.ModifiedFiles.Count) modified, $($state.UntrackedFiles.Count) untracked files" -ForegroundColor Green
            Write-Debug-Message "[DEBUG] Local git state summary -> Modified: $($state.ModifiedFiles.Count), Untracked: $($state.UntrackedFiles.Count)"
            return $state
            
        } catch {
            Write-Host "[WARNING] Error capturing local git state: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Debug-Message "[DEBUG] Exception during local git state capture: $($_.Exception.Message)"
            return $null
        } finally {
            Pop-Location
            Write-Debug-Message "[DEBUG] Restored original working directory after git state capture"
        }
    }
}

# 5: Helper function to check for git changes and prompt for commit
function Invoke-GitChangeDetection {
    param([string]$RepoPath)
    
    Write-Debug-Message "[DEBUG] Starting git change detection for '$RepoPath' (Location: $CONTAINER_LOCATION)"
    Write-Host "[INFO] Checking for git changes after container execution..." -ForegroundColor Cyan
    
    if (-not $script:GitStateBeforeContainer) {
        Write-Host "[INFO] No git state was captured before container start - skipping change detection" -ForegroundColor Cyan
        Write-Debug-Message "[DEBUG] Git change detection skipped: no baseline state available"
        return
    }
    
    $currentState = Get-GitRepositoryState -RepoPath $RepoPath -Pull
    if (-not $currentState) {
        Write-Host "[INFO] Could not get current git state - skipping change detection" -ForegroundColor Cyan
        Write-Debug-Message "[DEBUG] Git change detection skipped: unable to retrieve current state"
        return
    }
    
    # Check if this is a remote repository
    $isRemote = $CONTAINER_LOCATION -like "REMOTE@*"
    Write-Debug-Message "[DEBUG] Showing git commit dialog for '$RepoPath' (Remote: $isRemote)"
    
    try {
        if ($isRemote) {
            # Handle remote repository
            $remoteHost = "php-workstation@$($script:RemoteHostIp)"
            $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
            Write-Debug-Message "[DEBUG] Git change detection operating on remote host '$remoteHost'"
            
            # Get current status on remote
            $currentStatus = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git status --porcelain" 2>$null
            $currentFiles = ($currentStatus -split "`n" | Where-Object { $_.Trim() -ne "" })
            Write-Debug-Message "[DEBUG] Remote git status entries detected: $($currentFiles.Count)"
            
            # Check if there are any changes
            if ($currentFiles.Count -eq 0) {
                Write-Host "[INFO] No git changes detected after container execution" -ForegroundColor Green
                Write-Debug-Message "[DEBUG] Remote git change detection found no modifications"
                return
            }
            
            Write-Host "[INFO] Git changes detected on remote! Found $($currentFiles.Count) modified/new files:" -ForegroundColor Yellow
            foreach ($file in $currentFiles) {
                Write-Host "  $file" -ForegroundColor Yellow
            }
            Write-Host ""
            
            # Stage all changes on remote
            Write-Host "[INFO] Staging all changes on remote..." -ForegroundColor Cyan
            & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git add -A" 2>$null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[SUCCESS] Changes staged successfully on remote" -ForegroundColor Green
                Write-Debug-Message "[DEBUG] Remote git staging succeeded for '$RepoPath'"
                
                # Show the commit dialog for remote repository
                Show-GitCommitDialog -RepoPath $RepoPath
                
            } else {
                Write-Host "[ERROR] Failed to stage changes on remote" -ForegroundColor Red
                Write-Debug-Message "[DEBUG] Remote git staging failed for '$RepoPath' (ExitCode: $LASTEXITCODE)"
            }
            
        } else {
            # Handle local repository
            Push-Location $RepoPath
            
            # Get current status
            $currentStatus = git status --porcelain 2>$null
            $currentFiles = ($currentStatus -split "`n" | Where-Object { $_.Trim() -ne "" })
            Write-Debug-Message "[DEBUG] Local git status entries detected: $($currentFiles.Count)"
            
            # Check if there are any changes
            if ($currentFiles.Count -eq 0) {
                Write-Host "[INFO] No git changes detected after container execution" -ForegroundColor Green
                Write-Debug-Message "[DEBUG] Local git change detection found no modifications"
                return
            }
            
            Write-Host "[INFO] Git changes detected! Found $($currentFiles.Count) modified/new files:" -ForegroundColor Yellow
            foreach ($file in $currentFiles) {
                Write-Host "  $file" -ForegroundColor Yellow
            }
            Write-Host ""
            
            # Stage all changes
        Write-Host "[INFO] Staging all changes..." -ForegroundColor Cyan
        git add -A 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[SUCCESS] Changes staged successfully" -ForegroundColor Green
            Write-Debug-Message "[DEBUG] Local git staging succeeded for '$RepoPath'"
            
            # Show the commit dialog
            Show-GitCommitDialog -RepoPath $RepoPath
            
        } else {
            Write-Host "[ERROR] Failed to stage changes" -ForegroundColor Red
            Write-Debug-Message "[DEBUG] Local git staging failed for '$RepoPath' (ExitCode: $LASTEXITCODE)"
        }
        }
        
    } catch {
        Write-Host "[ERROR] Error during git change detection: $($_.Exception.Message)" -ForegroundColor Red
        Write-Debug-Message "[DEBUG] Exception raised during git change detection: $($_.Exception.Message)"
    } finally {
        if (-not $isRemote) {
            Pop-Location
            Write-Debug-Message "[DEBUG] Restored working directory after git change detection"
        }
    }
}

# 6: Helper function to show git commit dialog
function Show-GitCommitDialog {
    param([string]$RepoPath)
    
    # Check if this is a remote repository
    $isRemote = $CONTAINER_LOCATION -like "REMOTE@*"
    
    # Create the commit dialog form
    $commitForm = New-Object System.Windows.Forms.Form -Property @{
        Text = "Git Commit & Push"
        Size = New-Object System.Drawing.Size(600, 400)
        MaximizeBox = $false
        MinimizeBox = $false
        FormBorderStyle = "FixedDialog"
        TopMost = $true
    }
    Set-FormCenterOnCurrentScreen -Form $commitForm
    
    # Title label
    $titleLabel = New-Object System.Windows.Forms.Label -Property @{
        Text = "Git Changes Detected$(if($isRemote) { ' (Remote)' })"
        Location = New-Object System.Drawing.Point(20, 20)
        Size = New-Object System.Drawing.Size(560, 30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 12, [System.Drawing.FontStyle]::Bold)
        ForeColor = [System.Drawing.Color]::DarkBlue
    }
    $commitForm.Controls.Add($titleLabel)
    
    # Info label
    $infoLabel = New-Object System.Windows.Forms.Label -Property @{
        Text = "Changes have been detected and staged$(if($isRemote) { ' on remote host' }). Enter a commit message:"
        Location = New-Object System.Drawing.Point(20, 60)
        Size = New-Object System.Drawing.Size(560, 20)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
    }
    $commitForm.Controls.Add($infoLabel)
    
    # Commit message label
    $messageLabel = New-Object System.Windows.Forms.Label -Property @{
        Text = "Commit Message:"
        Location = New-Object System.Drawing.Point(20, 90)
        Size = New-Object System.Drawing.Size(150, 20)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    }
    $commitForm.Controls.Add($messageLabel)
    
    # Commit message textbox
    $messageTextBox = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(20, 115)
        Size = New-Object System.Drawing.Size(540, 120)
        Multiline = $true
        ScrollBars = "Vertical"
        Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)
        Text = "Update after container execution"
    }
    $commitForm.Controls.Add($messageTextBox)
    
    # Status label
    $statusLabel = New-Object System.Windows.Forms.Label -Property @{
        Text = "Status: Ready to commit"
        Location = New-Object System.Drawing.Point(20, 250)
        Size = New-Object System.Drawing.Size(540, 60)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        ForeColor = [System.Drawing.Color]::DarkGreen
    }
    $commitForm.Controls.Add($statusLabel)
    
    # Commit & Push button
    $commitButton = New-Object System.Windows.Forms.Button -Property @{
        Text = "Commit & Push"
        Location = New-Object System.Drawing.Point(350, 320)
        Size = New-Object System.Drawing.Size(120, 30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
        BackColor = [System.Drawing.Color]::LightGreen
    }
    
    # Skip button
    $skipButton = New-Object System.Windows.Forms.Button -Property @{
        Text = "Skip"
        Location = New-Object System.Drawing.Point(480, 320)
        Size = New-Object System.Drawing.Size(80, 30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        BackColor = [System.Drawing.Color]::LightGray
    }
    
    # Retry Push button (initially hidden)
    $retryPushButton = New-Object System.Windows.Forms.Button -Property @{
        Text = "Retry Push"
        Location = New-Object System.Drawing.Point(250, 320)
        Size = New-Object System.Drawing.Size(90, 30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        BackColor = [System.Drawing.Color]::LightBlue
        Visible = $false
    }
    
    # Open in VS Code button (initially hidden)
    $openVSCodeButton = New-Object System.Windows.Forms.Button -Property @{
        Text = "Open in VS Code"
        Location = New-Object System.Drawing.Point(140, 320)
        Size = New-Object System.Drawing.Size(100, 30)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        BackColor = [System.Drawing.Color]::LightCyan
        Visible = $false
    }
    
    # Function to perform git push with better error handling
    function Invoke-GitPush {
        param($RepoPath, $StatusLabel, $CommitForm)
        
        Write-Debug-Message "[DEBUG] Initiating git push for '$RepoPath' (Remote: $isRemote)"
        try {
            if ($isRemote) {
                # Handle remote repository operations
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                
                $StatusLabel.Text = "Status: Pushing to remote repository..."
                $StatusLabel.ForeColor = [System.Drawing.Color]::Blue
                $CommitForm.Refresh()
                
                # First, try to get remote URL to determine if it's HTTPS or SSH
                $remoteUrl = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote get-url origin" 2>$null
                $isHttpsRepo = $remoteUrl -match "^https://"
                $isSshRepo = $remoteUrl -match "^git@"
                Write-Debug-Message "[DEBUG] Remote repository URL detected: $remoteUrl (HTTPS: $isHttpsRepo, SSH: $isSshRepo)"
                
                # Configure git authentication on remote host
                if ($isSshRepo) {
                    Write-Host "[INFO] Remote repository uses SSH authentication" -ForegroundColor Cyan
                    Write-Host "[INFO] Configuring SSH agent on remote host..." -ForegroundColor Cyan
                    
                    # First check if SSH key exists on remote host
                $keyExists = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "test -f ~/.ssh/id_ed25519_$USERNAME && echo 'exists'" 2>$null
                Write-Debug-Message "[DEBUG] Remote SSH key existence check returned: $keyExists"
                    
                    if ($keyExists -ne "exists") {
                        Write-Host "[WARNING] SSH key ~/.ssh/id_ed25519_$USERNAME not found on remote host" -ForegroundColor Yellow
                        $StatusLabel.Text = "Status: Push failed - SSH key not found on remote host. Please ensure SSH key is properly mounted."
                        $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
                        return $false
                    }
                    
                    # Start SSH agent and add the key on remote host
                    $setupSSH = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost @"
cd '$RepoPath' && \
eval `$(ssh-agent -s) && \
ssh-add ~/.ssh/id_ed25519_$USERNAME 2>/dev/null && \
export GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' && \
git config core.sshCommand 'ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes'
"@ 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "[SUCCESS] SSH authentication configured on remote host" -ForegroundColor Green
                    } else {
                        Write-Host "[WARNING] SSH setup on remote host had issues: $setupSSH" -ForegroundColor Yellow
                    }
                    
                } elseif ($isHttpsRepo) {
                    Write-Host "[INFO] Remote repository uses HTTPS - converting to SSH for better authentication" -ForegroundColor Yellow
                    
                    # Extract owner/repo from HTTPS URL and convert to SSH
                    if ($remoteUrl -match "https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$") {
                        $owner = $matches[1]
                        $repo = $matches[2]
                        $sshUrl = "git@github.com:$owner/$repo.git"
                        
                        Write-Host "[INFO] Converting remote URL from HTTPS to SSH..." -ForegroundColor Cyan
                        Write-Host "[INFO] Old URL: $remoteUrl" -ForegroundColor Gray
                        Write-Host "[INFO] New URL: $sshUrl" -ForegroundColor Gray
                        
                        # Change the remote URL to SSH on remote host
                        $convertResult = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote set-url origin '$sshUrl'" 2>&1
                        
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "[SUCCESS] Converted remote URL to SSH successfully" -ForegroundColor Green
                            
                            # Now configure SSH authentication since we converted to SSH
                            $keyExists = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "test -f ~/.ssh/id_ed25519_$USERNAME && echo 'exists'" 2>$null
                            
                            if ($keyExists -ne "exists") {
                                Write-Host "[WARNING] SSH key ~/.ssh/id_ed25519_$USERNAME not found on remote host" -ForegroundColor Yellow
                                $StatusLabel.Text = "Status: Push failed - SSH key not found on remote host after HTTPS->SSH conversion."
                                $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
                                return $false
                            }
                            
                            # Configure SSH for the newly converted repository
                            $setupSSH = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost @"
cd '$RepoPath' && \
eval `$(ssh-agent -s) && \
ssh-add ~/.ssh/id_ed25519_$USERNAME 2>/dev/null && \
export GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' && \
git config core.sshCommand 'ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes'
"@ 2>&1
                            
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "[SUCCESS] SSH authentication configured after conversion" -ForegroundColor Green
                            } else {
                                Write-Host "[WARNING] SSH setup failed after conversion: $setupSSH" -ForegroundColor Yellow
                            }
                            
                            # Update our variables to reflect the conversion
                            $isSshRepo = $true
                            $isHttpsRepo = $false
                            
                        } else {
                            Write-Host "[ERROR] Failed to convert remote URL to SSH: $convertResult" -ForegroundColor Red
                            $StatusLabel.Text = "Status: Push failed - Could not convert HTTPS remote to SSH on remote host."
                            $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
                            return $false
                        }
                    } else {
                        Write-Host "[WARNING] Could not parse GitHub HTTPS URL for conversion: $remoteUrl" -ForegroundColor Yellow
                        $StatusLabel.Text = "Status: Push failed - Remote repository uses HTTPS which requires manual credential setup."
                        $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
                        return $false
                    }
                }
                
                # Capture both stdout and stderr from git push on remote
                # Use SSH method since we either started with SSH or converted HTTPS to SSH
                $pushCommand = "cd '$RepoPath' && eval `$(ssh-agent -s) && ssh-add ~/.ssh/id_ed25519_$USERNAME 2>/dev/null && export GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' && git push"
                
                $pushOutput = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost $pushCommand 2>&1
                $pushExitCode = $LASTEXITCODE
                $pushSummary = ($pushOutput -split "`r?`n" | Select-Object -First 3) -join " | "
                Write-Debug-Message "[DEBUG] Remote git push (agent approach) exit code: $pushExitCode, output: $pushSummary"
                
                # If SSH agent approach failed, try direct SSH key approach
                if ($pushExitCode -ne 0 -and ($pushOutput -match "ssh-add.*No such file|ssh-agent.*not found")) {
                    Write-Host "[INFO] SSH agent approach failed, trying direct SSH key method..." -ForegroundColor Yellow
                    
                    $directPushCommand = "cd '$RepoPath' && GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' git push"
                    $pushOutput = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost $directPushCommand 2>&1
                    $pushExitCode = $LASTEXITCODE
                    $pushSummary = ($pushOutput -split "`r?`n" | Select-Object -First 3) -join " | "
                    Write-Debug-Message "[DEBUG] Remote git push (direct key) exit code: $pushExitCode, output: $pushSummary"
                }
                $pushExitCode = $LASTEXITCODE
                
            } else {
                # Handle local repository operations
                Push-Location $RepoPath
                
                $StatusLabel.Text = "Status: Pushing to remote repository..."
                $StatusLabel.ForeColor = [System.Drawing.Color]::Blue
                $CommitForm.Refresh()
                
                # First, try to get remote URL to determine if it's HTTPS or SSH
                $remoteUrl = git remote get-url origin 2>$null
                $isHttpsRepo = $remoteUrl -match "^https://"
                $isSshRepo = $remoteUrl -match "^git@"
                Write-Debug-Message "[DEBUG] Local repository URL detected: $remoteUrl (HTTPS: $isHttpsRepo, SSH: $isSshRepo)"
                
                # Configure git authentication based on repository type
                if ($isSshRepo) {
                    # Use the same user-specific SSH key that the container uses
                    $userSshKeyPath = "${HOME}\.ssh\id_ed25519_${USERNAME}"
                    
                    if (Test-Path $userSshKeyPath) {
                        Write-Host "[INFO] Using user-specific SSH key: $userSshKeyPath" -ForegroundColor Cyan
                        # Set git SSH command to use the specific key (same as container)
                        $env:GIT_SSH_COMMAND = "ssh -i `"$userSshKeyPath`" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes"
                    } else {
                        Write-Host "[WARNING] User SSH key not found at: $userSshKeyPath" -ForegroundColor Yellow
                        Write-Host "[INFO] Trying default SSH configuration..." -ForegroundColor Cyan
                    }
                } elseif ($isHttpsRepo) {
                    # For HTTPS repos, ensure credential helper is configured and update if using old manager
                    $credHelper = git config --get credential.helper 2>$null
                    if (-not $credHelper -or $credHelper -eq "manager-core") {
                        Write-Host "[INFO] Configuring git credential helper for Windows..." -ForegroundColor Cyan
                        # Use the newer git-credential-manager (GCM was renamed from manager-core)
                        git config credential.helper manager 2>$null
                    }
                }
                
                # Capture both stdout and stderr from git push
                # Use env vars to disable interactive prompting for HTTPS repos only
                if ($isHttpsRepo) {
                    $env:GIT_TERMINAL_PROMPT = "0"
                    $env:GIT_ASKPASS = "echo"
                }
                
                $pushOutput = git push 2>&1
                $pushExitCode = $LASTEXITCODE
                $pushSummary = ($pushOutput -split "`r?`n" | Select-Object -First 3) -join " | "
                Write-Debug-Message "[DEBUG] Local git push exit code: $pushExitCode, output: $pushSummary"
                
                # Clean up environment variables
                if ($isHttpsRepo) {
                    Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
                    Remove-Item Env:GIT_ASKPASS -ErrorAction SilentlyContinue
                }
                if ($isSshRepo) {
                    Remove-Item Env:GIT_SSH_COMMAND -ErrorAction SilentlyContinue
                }
            }
            
            if ($pushExitCode -eq 0) {
                $StatusLabel.Text = "Status: Successfully committed and pushed!"
                $StatusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
                $CommitForm.Refresh()
                Start-Sleep -Seconds 2
                Write-Debug-Message "[DEBUG] Git push completed successfully for '$RepoPath'"
                $CommitForm.Close()
                return $true
            } else {
                # Parse the error to provide more helpful feedback
                $errorMessage = $pushOutput -join "`n"
                Write-Host "[GIT PUSH ERROR] $errorMessage" -ForegroundColor Red
                Write-Debug-Message "[DEBUG] Git push failed for '$RepoPath' with exit code $pushExitCode"
                
                # Provide specific error guidance based on error patterns
                if ($errorMessage -match "git-credential-manager-core was renamed") {
                    $StatusLabel.Text = "Status: Push failed - Git credential manager needs updating. Please update Git for Windows."
                } elseif ($errorMessage -match "Invalid username or token|Password authentication is not supported") {
                    if ($isRemote) {
                        $StatusLabel.Text = "Status: Push failed - Remote host needs GitHub authentication. Consider using SSH instead of HTTPS."
                    } else {
                        $StatusLabel.Text = "Status: Push failed - GitHub token expired/invalid. Please re-authenticate in VS Code or update your Personal Access Token."
                    }
                } elseif ($errorMessage -match "Authentication failed.*github\.com") {
                    if ($isRemote) {
                        $StatusLabel.Text = "Status: Push failed - Remote GitHub authentication failed. Check SSH key configuration on remote host."
                    } else {
                        $StatusLabel.Text = "Status: Push failed - GitHub authentication failed. Please sign in to GitHub in VS Code."
                    }
                } elseif ($errorMessage -match "Permission denied \(publickey\)|Host key verification failed") {
                    if ($isSshRepo) {
                        if ($isRemote) {
                            $StatusLabel.Text = "Status: Push failed - SSH key not configured on remote host or not added to GitHub."
                        } else {
                            $StatusLabel.Text = "Status: Push failed - SSH key not added to GitHub. Please add your public key to GitHub."
                        }
                    } else {
                        $StatusLabel.Text = "Status: Push failed - SSH authentication failed."
                    }
                } elseif ($errorMessage -match "could not read Username.*github\.com|Kein passendes.*Adresse gefunden") {
                    if ($isRemote) {
                        $StatusLabel.Text = "Status: HTTPS authentication failed on remote. Repository should be converted to SSH automatically."
                    } else {
                        $StatusLabel.Text = "Status: GitHub HTTPS authentication failed. Please authenticate in VS Code or use SSH."
                    }
                } elseif ($errorMessage -match "could not read Username|No such file or directory|/dev/tty: No such device") {
                    if ($isHttpsRepo) {
                        if ($isRemote) {
                            $StatusLabel.Text = "Status: Push failed - Remote host git credentials not configured. Consider using SSH key authentication."
                        } else {
                            $StatusLabel.Text = "Status: Push failed - Git credentials not configured. Please run 'git push' manually in VS Code or terminal to authenticate."
                        }
                    } else {
                        if ($isRemote) {
                            $StatusLabel.Text = "Status: Push failed - SSH key authentication issue on remote host."
                        } else {
                            $StatusLabel.Text = "Status: Push failed - SSH key authentication issue. Please check your SSH setup."
                        }
                    }
                } elseif ($errorMessage -match "ssh-add.*No such file or directory|ssh-agent.*not found") {
                    $StatusLabel.Text = "Status: Push failed - SSH agent not available on remote host. Retrying with direct SSH key..."
                } elseif ($errorMessage -match "Permission denied|Authentication failed") {
                    if ($isRemote) {
                        $StatusLabel.Text = "Status: Push failed - Authentication failed on remote host. Check SSH key and GitHub access."
                    } else {
                        $StatusLabel.Text = "Status: Push failed - Authentication failed. Please verify your credentials in VS Code."
                    }
                } elseif ($errorMessage -match "non-fast-forward|failed to push some refs") {
                    $StatusLabel.Text = "Status: Push failed - Remote has newer commits. Pull first, then retry."
                } elseif ($errorMessage -match "Connection timed out|Network is unreachable") {
                    $StatusLabel.Text = "Status: Push failed - Network issue. Check internet connection."
                } else {
                    if ($isRemote) {
                        $StatusLabel.Text = "Status: Push failed - SSH to remote host and run 'git push' manually to see detailed error."
                    } else {
                        $StatusLabel.Text = "Status: Push failed - Run 'git push' manually in VS Code terminal."
                    }
                }
                
                $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
                return $false
            }
            
        } catch {
            $StatusLabel.Text = "Status: Push error - $($_.Exception.Message)"
            $StatusLabel.ForeColor = [System.Drawing.Color]::Red
            Write-Debug-Message "[DEBUG] Exception during Invoke-GitPush: $($_.Exception.Message)"
            return $false
        } finally {
            if (-not $isRemote) {
                Pop-Location
                Write-Debug-Message "[DEBUG] Restored working directory after Invoke-GitPush"
            }
        }
    }
    
    # Commit button click event
    $commitButton.Add_Click({
        $commitMessage = $messageTextBox.Text.Trim()
        
        if ([string]::IsNullOrEmpty($commitMessage)) {
            $statusLabel.Text = "Status: Please enter a commit message"
            $statusLabel.ForeColor = [System.Drawing.Color]::Red
            return
        }
        
        $statusLabel.Text = "Status: Committing changes..."
        $statusLabel.ForeColor = [System.Drawing.Color]::Blue
        $commitButton.Enabled = $false
        $skipButton.Enabled = $false
        $retryPushButton.Visible = $false
        $openVSCodeButton.Visible = $false
        
        try {
            if ($isRemote) {
                # Handle remote repository commit
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                
                # Commit the changes on remote
                $statusLabel.Text = "Status: Creating commit on remote..."
                $commitForm.Refresh()
                
                $commitOutput = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git commit -m '$commitMessage'" 2>&1
                $commitExitCode = $LASTEXITCODE
                
            } else {
                # Handle local repository commit
                Push-Location $RepoPath
                
                # Commit the changes
                $statusLabel.Text = "Status: Creating commit..."
                $commitForm.Refresh()
                
                $commitOutput = git commit -m $commitMessage 2>&1
                $commitExitCode = $LASTEXITCODE
            }
            
            if ($commitExitCode -eq 0) {
                $statusLabel.Text = "Status: Commit successful. Pushing..."
                $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
                $commitForm.Refresh()
                
                # Try to push
                $pushSuccess = Invoke-GitPush -RepoPath $RepoPath -StatusLabel $statusLabel -CommitForm $commitForm
                
                if (-not $pushSuccess) {
                    # Show retry button and re-enable other buttons
                    $retryPushButton.Visible = $true
                    
                    # Show VS Code button for credential-related errors
                    if ($statusLabel.Text -match "credentials not configured|authentication issue|SSH key|VS Code") {
                        $openVSCodeButton.Visible = $true
                    }
                    
                    $commitButton.Text = "Commit Only"
                    $commitButton.Enabled = $true
                    $skipButton.Text = "Done"
                    $skipButton.Enabled = $true
                }
                
            } else {
                $commitError = $commitOutput -join "`n"
                Write-Host "[GIT COMMIT ERROR] $commitError" -ForegroundColor Red
                $statusLabel.Text = "Status: Commit failed - $($commitError.Split("`n")[0])"
                $statusLabel.ForeColor = [System.Drawing.Color]::Red
                $commitButton.Enabled = $true
                $skipButton.Enabled = $true
            }
            
        } catch {
            $statusLabel.Text = "Status: Error during commit: $($_.Exception.Message)"
            $statusLabel.ForeColor = [System.Drawing.Color]::Red
            $commitButton.Enabled = $true
            $skipButton.Enabled = $true
        } finally {
            if (-not $isRemote) {
                Pop-Location
            }
        }
    })
    
    # Retry Push button click event
    $retryPushButton.Add_Click({
        $retryPushButton.Enabled = $false
        
        $pushSuccess = Invoke-GitPush -RepoPath $RepoPath -StatusLabel $statusLabel -CommitForm $commitForm
        
        if (-not $pushSuccess) {
            $retryPushButton.Enabled = $true
        } else {
            $retryPushButton.Visible = $false
            $openVSCodeButton.Visible = $false
        }
    })
    
    # Open in VS Code button click event
    $openVSCodeButton.Add_Click({
        try {
            # Try to open the repository in VS Code
            $statusLabel.Text = "Status: Opening repository in VS Code..."
            $statusLabel.ForeColor = [System.Drawing.Color]::Blue
            $commitForm.Refresh()
            
            if ($isRemote) {
                # For remote repositories, we can't directly open them in VS Code
                # Instead, inform the user about manual git operations
                $statusLabel.Text = "Status: Remote repository - please connect via SSH and use 'git push' manually."
                $statusLabel.ForeColor = [System.Drawing.Color]::Orange
            } else {
                Start-Process "code" -ArgumentList $RepoPath -ErrorAction Stop
                
                $statusLabel.Text = "Status: Repository opened in VS Code. You can push manually there."
                $statusLabel.ForeColor = [System.Drawing.Color]::Green
            }
            
        } catch {
            $statusLabel.Text = "Status: Could not open VS Code. Please open the repository manually."
            $statusLabel.ForeColor = [System.Drawing.Color]::Orange
        }
    })
    
    # Skip button click event
    $skipButton.Add_Click({
        $commitForm.Close()
    })
    
    $commitForm.Controls.Add($commitButton)
    $commitForm.Controls.Add($skipButton)
    $commitForm.Controls.Add($retryPushButton)
    $commitForm.Controls.Add($openVSCodeButton)
    
    # Focus on the commit message textbox
    $messageTextBox.Select()
    $messageTextBox.SelectAll()
    
    # Show the dialog
    $commitForm.ShowDialog() | Out-Null
}

# Set repository/model and user-specific name for Docker container
$CONTAINER_NAME = "$($script:SelectedRepo)_$USERNAME"
Write-Debug-Message "[DEBUG] Container name set to: $CONTAINER_NAME"

# Initialize script-level variable to store used ports (those mapped to 8787)
$script:UsedPorts = @()

# Check for existing containers with the username
Write-Debug-Message "[DEBUG] STEP 5: Starting container status check for user: $USERNAME"
Write-Host ""
Write-Host "================================================"
Write-Host "  STEP 5: Container Status Check"
Write-Host "================================================"
Write-Host ""

Write-Host "[INFO] Checking for existing containers for user: $USERNAME" -ForegroundColor Cyan
Write-Host ""

try {
    Write-Debug-Message "[DEBUG] Starting Docker container existence check..."
    # Ensure SSH environment is set for remote Docker operations
    Set-DockerSSHEnvironment
    Write-Debug-Message "[DEBUG] SSH environment configured for Docker operations"
    
    # First, check ALL running containers to identify used ports (not just user-specific containers)
    Write-Debug-Message "[DEBUG] Checking all running containers for port usage"
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        $allRunningContainers = & docker ps --format "{{.Names}}\t{{.Ports}}" 2>$null
    } else {
        $allRunningContainers = & docker --context $script:RemoteContextName ps --format "{{.Names}}\t{{.Ports}}" 2>$null
    }
    
    # Parse all running containers to extract ports mapped to 8787
    if ($LASTEXITCODE -eq 0 -and $allRunningContainers) {
        $allContainerLines = $allRunningContainers -split "`n" | Where-Object { $_.Trim() -ne "" }
        foreach ($containerLine in $allContainerLines) {
            # Port format: 0.0.0.0:8787->8787/tcp or 0.0.0.0:8788->8787/tcp
            if ($containerLine -match '0\.0\.0\.0:(\d{4})->8787/tcp') {
                $portNumber = $matches[1]
                if ($script:UsedPorts -notcontains $portNumber) {
                    $script:UsedPorts += $portNumber
                    Write-Debug-Message "[DEBUG] Found port $portNumber mapped to 8787 (from all containers)"
                }
            }
        }
    }
    
    # Get all containers (running and stopped) that contain the username
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        Write-Debug-Message "[DEBUG] Checking local Docker containers for user: $USERNAME"
        $existingContainers = & docker ps -a --filter "name=_$USERNAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>$null
    } else {
        Write-Debug-Message "[DEBUG] Checking remote Docker containers using context: $script:RemoteContextName"
        # For remote, use the context we set up
        $existingContainers = & docker --context $script:RemoteContextName ps -a --filter "name=_$USERNAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Image}}" 2>$null
    }
    
    Write-Debug-Message "[DEBUG] Docker ps command exit code: $LASTEXITCODE"
    
    if ($LASTEXITCODE -ne 0) {
        Write-Debug-Message "[DEBUG] Docker ps command failed, containers may not be accessible"
        Write-Host "[WARNING] Could not check for existing containers. Consider checking manually in Docker Desktop!" -ForegroundColor Yellow
        Write-Host "  Continuing with container launch..."
        Write-Host ""
    } else {
        Write-Debug-Message "[DEBUG] Docker ps command successful, processing container list"
        Write-Debug-Message "[DEBUG] Raw Docker ps output: $existingContainers"
        
        # Parse the output to find containers
        $containerList = $existingContainers -split "`n" | Where-Object { $_ -match "_$USERNAME" -and $_ -notmatch "^NAMES" }
        Write-Debug-Message "[DEBUG] Filtered container list count: $($containerList.Count)"
        
        if ($containerList.Count -gt 0) {
            Write-Debug-Message "[DEBUG] Found existing containers for user: $USERNAME"
            Write-Host "[INFO] Found existing containers for user '$USERNAME':" -ForegroundColor Cyan
            Write-Host ""
            
            # Display existing containers
            Write-Host "  Existing Containers:"
            Write-Host "  " + ("=" * 80)
            foreach ($container in $containerList) {
                if ($container.Trim() -ne "") {
                    Write-Host "  $container"
                }
            }
            Write-Host "  " + ("=" * 80)
            Write-Host ""
            
            # Display summary of used ports (from all containers, not just user-specific)
            if ($script:UsedPorts.Count -gt 0) {
                Write-Host "[INFO] Ports currently mapped to 8787 (across all containers): $($script:UsedPorts -join ', ')" -ForegroundColor Cyan
                Write-Host ""
            }
            
            # Check specifically for running containers
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $runningContainers = & docker ps --filter "name=_$USERNAME" --format "{{.Names}}" 2>$null
            } else {
                $runningContainers = & docker --context $script:RemoteContextName ps --filter "name=_$USERNAME" --format "{{.Names}}" 2>$null
            }
            $runningList = $runningContainers -split "`n" | Where-Object { $_ -match "_$USERNAME" -and $_.Trim() -ne "" }
            
            if ($runningList.Count -gt 0) {
                Write-Host "[WARNING] Found $($runningList.Count) RUNNING container(s) for user '$USERNAME':" -ForegroundColor Yellow
                foreach ($runningContainer in $runningList) {
                    if ($runningContainer.Trim() -ne "") {
                        Write-Host "  - $runningContainer (RUNNING)"
                    }
                }
                Write-Host ""
                Write-Host "RECOMMENDATION: Stop existing containers before launching new ones"
                Write-Host "to avoid port conflicts and resource issues."
                Write-Host ""
                
                # Prompt user for action
                $result = [System.Windows.Forms.MessageBox]::Show(
                    "Found running containers for user '$USERNAME'.`n`n" +
                    "Running multiple containers for the same user may cause:`n" +
                    "- Port conflicts`n" +
                    "- Resource conflicts`n" +
                    "- Confusion about which container to use`n`n" +
                    "RECOMMENDATION: Stop existing containers first.`n`n" +
                    "Do you want to stop all existing containers for user '$USERNAME'?`n`n" +
                    "Click 'Yes' to stop existing containers`n" +
                    "Click 'No' to continue with existing containers running`n" +
                    "Click 'Cancel' to abort and manage containers manually",
                    "Existing Containers Found - $USERNAME",
                    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                
                if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                    Write-Host "[INFO] User chose to stop existing containers" -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "Stopping existing containers for user '$USERNAME'..."
                    
                    # Ensure SSH environment is set for remote Docker operations
                    Set-DockerSSHEnvironment
                    
                    foreach ($runningContainer in $runningList) {
                        if ($runningContainer.Trim() -ne "") {
                            Write-Host "  Stopping container: $runningContainer"
                            if ($CONTAINER_LOCATION -eq "LOCAL") {
                                & docker stop $runningContainer 2>$null
                            } else {
                                & docker --context $script:RemoteContextName stop $runningContainer 2>$null
                            }
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "    [SUCCESS] Stopped: $runningContainer" -ForegroundColor Green
                            } else {
                                Write-Host "    [WARNING] Could not stop: $runningContainer" -ForegroundColor Yellow
                            }
                        }
                    }
                    Write-Host ""
                    Write-Host "[SUCCESS] Container cleanup completed" -ForegroundColor Green
                    
                } elseif ($result -eq [System.Windows.Forms.DialogResult]::No) {
                    Write-Host "[INFO] User chose to continue with existing containers running" -ForegroundColor Cyan
                    Write-Host "[WARNING] Proceeding with existing containers running may cause conflicts" -ForegroundColor Yellow
                    
                } else {
                    Write-Host "[INFO] User cancelled container launch" -ForegroundColor Cyan
                    Write-Host "Please manage existing containers manually using:"
                    Write-Host "  docker ps -a                    # List all containers"
                    Write-Host "  docker stop <container_name>    # Stop a container"
                    Write-Host "  docker rm <container_name>      # Remove a container"
                    Write-Host "Otherwise use Docker Desktop app!"
                    Write-Host ""
                    exit 0
                }
            } else {
                Write-Host "[INFO] Found existing containers, but none are currently running" -ForegroundColor Cyan
                Write-Host "  These stopped containers will not interfere with new containers"
                Write-Host ""
            }
        } else {
            Write-Host "[INFO] No existing containers found for user '$USERNAME'" -ForegroundColor Cyan
            Write-Host "  Ready to create new container: $CONTAINER_NAME"
            Write-Host ""
        }
    }} catch {
    Write-Host "[WARNING] Error checking for existing containers: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Continuing with container launch..."
    Write-Host ""
}


#--------------------------------------------------------#
#   STEP 6: Container Management Interface               #
#--------------------------------------------------------#

Write-Host ""
Write-Host "================================================"
Write-Host "  STEP 6: Container Management"
Write-Host "================================================"
Write-Host ""

Write-Host "[INFO] Preparing container management interface..." -ForegroundColor Cyan
Write-Host "  Container Name: $CONTAINER_NAME"
Write-Host "  Selected Repository: $($script:SelectedRepo)"
Write-Host "  Username: $USERNAME"
Write-Host ""

# Check if the specific container is currently running and retrieve its details
$isContainerRunning = $false
$existingContainerPort = $null
$existingContainerUrl = $null
try {
    # Ensure SSH environment is set for remote Docker operations
    Set-DockerSSHEnvironment
    
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        $runningCheck = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}	{{.Ports}}" 2>$null
    } else {
        $runningCheck = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}	{{.Ports}}" 2>$null
    }
    if ($null -eq $runningCheck) {
        $runningCheck = "this_container_does_not_exist" # Default to non-matching string
    }
    if ($LASTEXITCODE -eq 0 -and $runningCheck.Trim() -match "^$CONTAINER_NAME") {
        $isContainerRunning = $true
        
        # Extract port information from the running container
        if ($runningCheck -match '0\.0\.0\.0:(\d{4})->8787/tcp') {
            $existingContainerPort = $matches[1]
            Write-Host "[INFO] Container '$CONTAINER_NAME' is currently RUNNING on port $existingContainerPort" -ForegroundColor Green
            
            # Build the access URL for the existing container
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $existingContainerUrl = "http://localhost:$existingContainerPort"
            } else {
                $existingContainerUrl = "http://$($script:RemoteHostIp):$existingContainerPort"
            }
            Write-Host "[INFO] Access URL: $existingContainerUrl" -ForegroundColor Cyan
        } else {
            Write-Host "[INFO] Container '$CONTAINER_NAME' is currently RUNNING (port info not detected)" -ForegroundColor Cyan
        }
    } else {
        Write-Host "[INFO] Container '$CONTAINER_NAME' is currently STOPPED or does not exist" -ForegroundColor Cyan
    }
} catch {
    Write-Host "[WARNING] Could not check container status: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Creating container management interface..."
Write-Host ""

# Create the main container management form (size adjusts if container is running)
$formContainer = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Container Management - IMPACT NCD Germany'
    Size = New-Object System.Drawing.Size(500,$(if ($isContainerRunning) { 505 } else { 480 }))
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}
Set-FormCenterOnCurrentScreen -Form $formContainer

# Instruction rich textbox
$labelInstruction = New-Object System.Windows.Forms.RichTextBox -Property @{ 
    Location = New-Object System.Drawing.Point(10,10)
    Size = New-Object System.Drawing.Size(470,150)
    ReadOnly = $true
    BorderStyle = 'None'
    BackColor = $formContainer.BackColor
    ScrollBars = 'None'
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}

# Add formatted text to instruction rich textbox
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelInstruction.AppendText("Your username is: ")
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$labelInstruction.AppendText("$USERNAME`n`n")

$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelInstruction.AppendText("The Rstudio Server username is: ")
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$labelInstruction.AppendText("rstudio`n")

$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelInstruction.AppendText("Your Rstudio Server password is: ")
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$labelInstruction.AppendText("$PASSWORD`n`n")

$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelInstruction.AppendText("The repository you are using is: ")
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$labelInstruction.AppendText("$($script:SelectedRepo)`n")

$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelInstruction.AppendText("The name of the container will be: ")
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
$labelInstruction.AppendText("$CONTAINER_NAME`n`n")

$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
$labelInstruction.AppendText("Status: ")
$labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
if ($isContainerRunning) {
    $labelInstruction.SelectionColor = [System.Drawing.Color]::Green
    $labelInstruction.AppendText("RUNNING")
    
    # Add access URL information if container is already running
    if ($existingContainerUrl) {
        $labelInstruction.SelectionColor = [System.Drawing.Color]::Black
        $labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        $labelInstruction.AppendText("`n`n")
        $labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
        $labelInstruction.AppendText("Access your running container at:`n")
        $labelInstruction.SelectionFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
        $labelInstruction.SelectionColor = [System.Drawing.Color]::Blue
        $labelInstruction.AppendText("$existingContainerUrl")
    }
} else {
    $labelInstruction.SelectionColor = [System.Drawing.Color]::Red
    $labelInstruction.AppendText("STOPPED")
}

$formContainer.Controls.Add($labelInstruction)

# Start/Access button (text changes based on container state)
$buttonStart = New-Object System.Windows.Forms.Button -Property @{
    Text = $(if ($isContainerRunning) { 'Access Container' } else { 'Start Container' })
    Location = New-Object System.Drawing.Point(100,165)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    Enabled = $true
}
$formContainer.Controls.Add($buttonStart)

# Stop button  
$buttonStop = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Stop Container'
    Location = New-Object System.Drawing.Point(250,165)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    Enabled = $isContainerRunning
}
$formContainer.Controls.Add($buttonStop)

# Session info label (if container is running)
if ($isContainerRunning) {
    $labelSessionInfo = New-Object System.Windows.Forms.Label -Property @{ 
        Text = "💡 Your session is persistent - you can close this window and reconnect anytime!"
        Location = New-Object System.Drawing.Point(10,220)
        Size = New-Object System.Drawing.Size(470,20)
        Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Italic)
        ForeColor = [System.Drawing.Color]::DarkGreen
    }
    $formContainer.Controls.Add($labelSessionInfo)
    
    # Adjust positions for controls below
    $advancedOptionsYPosition = 245
} else {
    $advancedOptionsYPosition = 220
}

# Advanced Options section
$labelAdvanced = New-Object System.Windows.Forms.Label -Property @{ 
    Text = "Advanced Options:"
    Location = New-Object System.Drawing.Point(10,$advancedOptionsYPosition)
    Size = New-Object System.Drawing.Size(470,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formContainer.Controls.Add($labelAdvanced)

# Checkbox option
$checkBoxVolumes = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'Use Docker Volumes'
    Location = New-Object System.Drawing.Point(20,$(if ($isContainerRunning) { 270 } else { 245 }))
    Size = New-Object System.Drawing.Size(150,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$formContainer.Controls.Add($checkBoxVolumes)

# Rebuild image checkbox option
$checkBoxRebuild = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'Rebuild Docker image for repository'
    Location = New-Object System.Drawing.Point(175,$(if ($isContainerRunning) { 270 } else { 245 }))
    Size = New-Object System.Drawing.Size(250,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$formContainer.Controls.Add($checkBoxRebuild)

# High computational demand checkbox option
$checkBoxHighCompute = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'High computational demand'
    Location = New-Object System.Drawing.Point(20,$(if ($isContainerRunning) { 295 } else { 270 }))
    Size = New-Object System.Drawing.Size(200,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$formContainer.Controls.Add($checkBoxHighCompute)

# Port override label and textbox
$labelPort = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Port Override:'
    Location = New-Object System.Drawing.Point(20,$(if ($isContainerRunning) { 330 } else { 305 }))
    Size = New-Object System.Drawing.Size(90,20)
}
$formContainer.Controls.Add($labelPort)
$textBoxPort = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(110,$(if ($isContainerRunning) { 325 } else { 300 }))
    Size = New-Object System.Drawing.Size(100,20)
    Text = '8787'
}
$formContainer.Controls.Add($textBoxPort)

# Custom parameters label and textbox
$labelParams = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Custom Parameters:'
    Location = New-Object System.Drawing.Point(20,$(if ($isContainerRunning) { 365 } else { 340 }))
    Size = New-Object System.Drawing.Size(120,20)
}
$formContainer.Controls.Add($labelParams)
$textBoxParams = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(140,$(if ($isContainerRunning) { 360 } else { 335 }))
    Size = New-Object System.Drawing.Size(200,20)
    Text = ''
}
$formContainer.Controls.Add($textBoxParams)

# sim_design.yaml file label and textbox
$labelSimDesign = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'sim_design.yaml file used for directories:'
    Location = New-Object System.Drawing.Point(20,$(if ($isContainerRunning) { 400 } else { 375 }))
    Size = New-Object System.Drawing.Size(230,20)
}
$formContainer.Controls.Add($labelSimDesign)
$textBoxSimDesign = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(250,$(if ($isContainerRunning) { 395 } else { 370 }))
    Size = New-Object System.Drawing.Size(220,20)
    Text = '..\inputs\sim_design.yaml'
}
$formContainer.Controls.Add($textBoxSimDesign)

# OK and Cancel buttons
$buttonOK = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Close'
    Location = New-Object System.Drawing.Point(300,$(if ($isContainerRunning) { 415 } else { 390 }))
    Size = New-Object System.Drawing.Size(75,30)
}
$formContainer.Controls.Add($buttonOK)

$buttonCancel = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Cancel'
    Location = New-Object System.Drawing.Point(395,$(if ($isContainerRunning) { 415 } else { 390 }))
    Size = New-Object System.Drawing.Size(75,30)
    DialogResult = [System.Windows.Forms.DialogResult]::Cancel
}
$formContainer.Controls.Add($buttonCancel)

# Add form closing event handler to check if container is running
$formContainer.Add_FormClosing({
    param(
        [object]$sender,
        [System.Windows.Forms.FormClosingEventArgs]$formClosingEventArgs
    )
    [void]$sender
    
    # Check if container is currently running before allowing close
    $currentlyRunning = $false
    try {
        Set-DockerSSHEnvironment
        
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            $runningCheck = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
        } else {
            $runningCheck = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
        }
        
        if ($null -eq $runningCheck) {
            $runningCheck = "this_container_does_not_exist"
        }
        
        if ($LASTEXITCODE -eq 0 -and $runningCheck.Trim() -eq $CONTAINER_NAME) {
            $currentlyRunning = $true
        }
    } catch {
        # If we can't check, assume it might be running to be safe
        Write-Debug-Message "[DEBUG] Could not check container status during form close: $($_.Exception.Message)"
        $currentlyRunning = $false
    }
    
    # If container is running, show warning and cancel the close
    if ($currentlyRunning) {
        [void][System.Windows.Forms.MessageBox]::Show(
            "The container '$CONTAINER_NAME' is still RUNNING.`n`nPlease stop the container before closing!`n`nClick 'Stop Container' to stop it, then try closing again.",
            "Container Still Running",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        
        # Cancel the form closing event
        $formClosingEventArgs.Cancel = $true
        Write-Host "[WARNING] Form close cancelled - container '$CONTAINER_NAME' is still running" -ForegroundColor Yellow
    } else {
        Write-Host "[INFO] Container management form closing - no running containers detected" -ForegroundColor Cyan
    }
})

# Set default buttons
$formContainer.AcceptButton = $buttonOK
$formContainer.CancelButton = $buttonCancel

# Helper function to update the instruction RichTextBox
function Update-InstructionText {
    param(
        [string]$Status,
        [string]$Location = $CONTAINER_LOCATION,
        [string]$VolumesInfo = ""
    )
    
    Write-Debug-Message "[DEBUG] Updating instruction text (Status=$Status, Location=$Location, Volumes=$VolumesInfo)"

    # Clear existing content
    $labelInstruction.Clear()
    
    # Add formatted text to instruction rich textbox
    $boldFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    $regularFont = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)

    $labelInstruction.SelectionFont = $boldFont
    $labelInstruction.AppendText("Your username is: ")
    $labelInstruction.SelectionFont = $regularFont
    $labelInstruction.AppendText("$USERNAME`n`n")
    
    $labelInstruction.SelectionFont = $boldFont
    $labelInstruction.AppendText("The Rstudio Server username is: ")
    $labelInstruction.SelectionFont = $regularFont
    $labelInstruction.AppendText("rstudio`n")
    
    $labelInstruction.SelectionFont = $boldFont
    $labelInstruction.AppendText("Your Rstudio Server password is: ")
    $labelInstruction.SelectionFont = $regularFont
    $labelInstruction.AppendText("$PASSWORD`n`n")
    
    $labelInstruction.SelectionFont = $boldFont
    $labelInstruction.AppendText("The repository you are using is: ")
    $labelInstruction.SelectionFont = $regularFont
    $labelInstruction.AppendText("$($script:SelectedRepo)`n")
    
    $labelInstruction.SelectionFont = $boldFont
    $labelInstruction.AppendText("The name of the container will be: ")
    $labelInstruction.SelectionFont = $regularFont
    $labelInstruction.AppendText("$CONTAINER_NAME`n`n")
    
    $labelInstruction.SelectionFont = $boldFont
    $labelInstruction.AppendText("Status: ")
    $labelInstruction.SelectionFont = $boldFont
    if ($Status -eq "RUNNING") {
        $labelInstruction.SelectionColor = [System.Drawing.Color]::Green
        $labelInstruction.AppendText("RUNNING")
    } else {
        $labelInstruction.SelectionColor = [System.Drawing.Color]::Red
        $labelInstruction.AppendText("STOPPED")
    }
    
    # Add location and volumes info if provided
    if ($Location) {
        $labelInstruction.SelectionColor = [System.Drawing.Color]::Black
        $labelInstruction.SelectionFont = $boldFont
        $labelInstruction.AppendText(" Location: ")
        $labelInstruction.SelectionFont = $regularFont
        $labelInstruction.AppendText($Location)
    }
    
    if ($VolumesInfo) {
        $labelInstruction.SelectionColor = [System.Drawing.Color]::Black
        $labelInstruction.SelectionFont = $boldFont
        $labelInstruction.AppendText(" Volumes: ")
        $labelInstruction.SelectionFont = $regularFont
        $labelInstruction.AppendText($VolumesInfo)
    }
}

# Declare variables at form scope so both event handlers can access them
$script:UseVolumes = $false
$script:HighComputeDemand = $false
$script:OutputDir = $null
$script:SynthpopDir = $null
$script:VolumeOutput = $null
$script:VolumeSynthpop = $null
$script:UserId = $null
$script:GroupId = $null
$script:RsyncImage = $null

# Event handlers
$buttonStart.Add_Click({
    # First check if container is already running (session recovery)
    Write-Host ""
    Write-Host "[INFO] Checking container status..." -ForegroundColor Cyan
    Write-Host "  Container: $CONTAINER_NAME"
    Write-Host ""
    
    try {
        Set-DockerSSHEnvironment
        $containerCheckResult = $null
        
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            $containerCheckResult = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}	{{.Ports}}" 2>$null
        } else {
            $containerCheckResult = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}	{{.Ports}}" 2>$null
        }
        
        if ($LASTEXITCODE -eq 0 -and $containerCheckResult -and $containerCheckResult.Trim() -match "^$CONTAINER_NAME") {
            # Container is already running - provide access information
            Write-Host "[INFO] Container '$CONTAINER_NAME' is already RUNNING!" -ForegroundColor Green
            
            # Extract port and build URL
            $portNumber = "8787"
            if ($containerCheckResult -match '0\.0\.0\.0:(\d{4})->8787/tcp') {
                $portNumber = $matches[1]
            }
            
            $accessUrl = if ($CONTAINER_LOCATION -eq "LOCAL") {
                "http://localhost:$portNumber"
            } else {
                "http://$($script:RemoteHostIp):$portNumber"
            }
            
            Write-Host "[INFO] Container details:" -ForegroundColor Cyan
            Write-Host "  URL: $accessUrl" -ForegroundColor Cyan
            Write-Host "  Username: rstudio" -ForegroundColor Cyan
            Write-Host "  Password: $PASSWORD" -ForegroundColor Cyan
            Write-Host ""
            
            # Show info dialog with access details and option to open browser
            $resumeMessage = "Your container is already running!`n`n" +
                           "You can continue your work session by accessing:`n`n" +
                           "URL: $accessUrl`n" +
                           "Username: rstudio`n" +
                           "Password: $PASSWORD`n`n" +
                           "Container: $CONTAINER_NAME`n" +
                           "Location: $CONTAINER_LOCATION`n`n" +
                           "Would you like to open the RStudio Server in your browser?"
            
            $result = [System.Windows.Forms.MessageBox]::Show(
                $resumeMessage,
                "Resume Existing Session - $CONTAINER_NAME",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                Write-Host "[INFO] Opening browser to access RStudio Server..." -ForegroundColor Cyan
                Start-Process $accessUrl
            }
            
            Write-Host "[INFO] Session resumed - container continues running" -ForegroundColor Green
            Write-Host ""
            
            # Update UI to reflect running state
            $buttonStart.Text = 'Access Container'
            $buttonStop.Enabled = $true
            Update-InstructionText -Status "RUNNING" -Location $CONTAINER_LOCATION -VolumesInfo $(if($checkBoxVolumes.Checked) { "Enabled" } else { "Disabled" })
            
            return  # Exit the click handler without starting new container
        }
    } catch {
        Write-Host "[WARNING] Error checking container status: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[INFO] Proceeding with container startup..." -ForegroundColor Cyan
    }
    
    Write-Host "[INFO] Container is starting up..." -ForegroundColor Cyan
    Write-Host "  Container: $CONTAINER_NAME"
    
    # Get options from form and store in script scope
    $script:UseVolumes = $checkBoxVolumes.Checked
    $useVolumes = $script:UseVolumes  # Keep local copy for backwards compatibility
    $script:RebuildImage = $checkBoxRebuild.Checked
    $rebuildImage = $script:RebuildImage  # Keep local copy for backwards compatibility
    $script:HighComputeDemand = $checkBoxHighCompute.Checked
    $highComputeDemand = $script:HighComputeDemand  # Keep local copy for backwards compatibility
    $portOverride = $textBoxPort.Text.Trim()
    $customParams = $textBoxParams.Text.Trim()
    $SimDesignYAML = $textBoxSimDesign.Text.Trim()
    
    # Validate port override is not already in use
    if ($portOverride -and $script:UsedPorts -contains $portOverride) {
        Write-Host "[ERROR] Port $portOverride is already in use by another container!" -ForegroundColor Red
        Write-Host "  Ports currently in use: $($script:UsedPorts -join ', ')" -ForegroundColor Yellow
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show(
            "Port $portOverride is already in use by another container!`n`n" +
            "Ports currently mapped to 8787:`n$($script:UsedPorts -join ', ')`n`n" +
            "Please select a different port number between 8787 and 8800 that is not in use.",
            "Port Conflict - $portOverride",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return  # Exit the button click handler without starting container
    }
    
    Write-Host "  Advanced Options:"
    Write-Host "    Use Volumes: $useVolumes"
    Write-Host "    Rebuild Image: $rebuildImage"
    Write-Host "    High Computational Demand: $highComputeDemand"
    Write-Host "    Port Override: $(if($portOverride) { $portOverride } else { 'Default' })"
    Write-Host "    Custom Parameters: $(if($customParams) { $customParams } else { 'None' })"
    Write-Host "    sim_design.yaml file: $(if($SimDesignYAML) { $SimDesignYAML } else { 'Default' })"
    Write-Host ""

    # Resolve docker setup directory based on current model
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        if (-not $script:LocalRepoPath) {
            Write-Host "[FATAL ERROR] No local repository path found. Please restart the application and select a folder."
            Exit 1
        }
        $ScriptDir = "$script:LocalRepoPath\docker_setup"
        $ProjectRoot = $script:LocalRepoPath
        Write-Host "[INFO] Using local repository path: $script:LocalRepoPath" -ForegroundColor Cyan
        
        # Validate that the docker_setup directory exists locally
        if (-not (Test-Path $ScriptDir)) {
            Write-Host "[FATAL ERROR] Your repository has no Docker setup directory at '$ScriptDir'"
            Exit 1
        }
    } else {
        # Remote operation
        if (-not $script:RemoteRepoPath) {
            Write-Host "[FATAL ERROR] No remote repository path found. Please restart the application and select a repository."
            Exit 1
        }
        $ScriptDir = "$script:RemoteRepoPath/docker_setup"
        $ProjectRoot = $script:RemoteRepoPath
        Write-Host "[INFO] Using remote repository path: $script:RemoteRepoPath" -ForegroundColor Cyan
        
        # For remote, we'll validate paths during Docker build, not here with Test-Path
        Write-Host "[INFO] Remote docker_setup directory: $ScriptDir" -ForegroundColor Cyan
    }

    # ProjectRoot is already set correctly in the if/else block above - don't override it
    Write-Host "[INFO] Project root directory: $ProjectRoot" -ForegroundColor Cyan

    # If SimDesignYaml is a relative path, resolve it relative to the project root
    if (-not [System.IO.Path]::IsPathRooted($SimDesignYaml)) {
        # Normalize path separators to forward slashes for cross-platform compatibility
        $SimDesignYamlNormalized = $SimDesignYaml -replace '\\', '/'
        $TempPath = "$ProjectRoot/$SimDesignYamlNormalized" -replace '/+', '/'
        
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            # For local operations, resolve the path to handle .. components properly
            $SimDesignYaml = (Resolve-Path $TempPath -ErrorAction SilentlyContinue).Path
            if (-not $SimDesignYaml) {
                # If Resolve-Path fails, try manual construction (for the actual inputs directory)
                if ($SimDesignYamlNormalized -eq "../inputs/sim_design.yaml") {
                    $SimDesignYaml = "$ProjectRoot/inputs/sim_design.yaml"
                } else {
                    $SimDesignYaml = $TempPath
                }
            }
        } else {
            # For remote operations, construct the path manually (can't use Resolve-Path on remote paths)
            if ($SimDesignYamlNormalized -eq "../inputs/sim_design.yaml") {
                $SimDesignYaml = "$ProjectRoot/inputs/sim_design.yaml"
            } else {
                $SimDesignYaml = $TempPath
            }
        }
    }

    # Validate that the YAML file exists
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        if (-not (Test-Path $SimDesignYaml)) {
            Write-Host "[FATAL ERROR] YAML file not found at '$SimDesignYaml'"
            Write-Host "Original path provided: '..\inputs\sim_design.yaml'"
            Write-Host "Project root: '$ProjectRoot'"
            Exit 1
        }
    } else {
        # For remote operations, we'll validate the YAML file exists during Docker build
        Write-Host "[INFO] Remote YAML file path: $SimDesignYaml" -ForegroundColor Cyan
        Write-Host "[INFO] YAML file existence will be validated during Docker build" -ForegroundColor Cyan
    }

    Write-Host "[INFO] Using configuration file: $SimDesignYaml" -ForegroundColor Cyan
    Write-Host ""

    # Check if Docker image for the current model already exists
    $DockerImageName = $script:SelectedRepo.ToLower()
    Write-Host "[INFO] Checking if a Docker image for your repo (e.g. $DockerImageName) already exists..." -ForegroundColor Cyan
    Write-Host ""

    # Check if image exists (unless rebuild is forced)
    $imageExists = $false
    if ($rebuildImage) {
        Write-Host "[INFO] Force rebuild is enabled - will rebuild image even if it exists" -ForegroundColor Cyan
        Write-Host ""
        $imageExists = $false
    } else {
        try {
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                # Check locally
                $imageCheck = & docker images --format "{{.Repository}}" | Where-Object { $_ -eq $DockerImageName }
                $imageExists = $null -ne $imageCheck
            } else {
                # Check on remote host using Docker context
                Set-DockerSSHEnvironment
                Write-Host "[INFO] Checking for Docker image on remote host using context: $script:RemoteContextName" -ForegroundColor Cyan
                $imageCheck = & docker --context $script:RemoteContextName images --format "{{.Repository}}" 2>$null | Where-Object { $_ -eq $DockerImageName }
                $imageExists = $null -ne $imageCheck
                
                if ($imageExists) {
                    Write-Host "[INFO] Found existing image '$DockerImageName' on remote host" -ForegroundColor Cyan
                } else {
                    Write-Host "[INFO] Image '$DockerImageName' not found on remote host" -ForegroundColor Cyan
                }
            }
        } catch {
            Write-Host "[WARNING] Could not check for existing Docker image: $($_.Exception.Message)" -ForegroundColor Yellow
            $imageExists = $false
        }
    }

    if ($imageExists) {
        Write-Host "[SUCCESS] Docker image '$DockerImageName' that can be used for your container already exists" -ForegroundColor Green
        Write-Host ""
    } else {
        if ($rebuildImage) {
            Write-Host "[INFO] Rebuilding Docker image '$DockerImageName' as requested (force rebuild enabled)..." -ForegroundColor Cyan
        } else {
            Write-Host "[INFO] Docker image '$DockerImageName' does not exist, building from Dockerfile..." -ForegroundColor Cyan
        }
        Write-Host ""

        # Determine Dockerfile path for model image build
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            $dockerfilePath = Join-Path $script:LocalRepoPath "docker_setup\Dockerfile.IMPACTncdGER"
            $dockerContextPath = $script:LocalRepoPath
        } else {
            $dockerfilePath = "$script:RemoteRepoPath/docker_setup/Dockerfile.IMPACTncdGER"
            $dockerContextPath = $script:RemoteRepoPath
        }

        Write-Host "[INFO] Using Dockerfile: $dockerfilePath" -ForegroundColor Cyan
        Write-Host ""

        Write-Host "[INFO] Docker build context: $dockerContextPath" -ForegroundColor Cyan
        Write-Host ""

        # Check if Dockerfile exists
        $dockerfileExists = $false
        try {
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $dockerfileExists = Test-Path $dockerfilePath
            } else {
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                $dockerfileCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "test -f '$dockerfilePath' && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1
                $dockerfileExists = $dockerfileCheck -match "EXISTS"
            }
        } catch {
            Write-Host "[ERROR] Could not check for Dockerfile: $($_.Exception.Message)" -ForegroundColor Red
            $dockerfileExists = $false
        }

        if (-not $dockerfileExists) {
            Write-Host "[FATAL ERROR] Dockerfile not found at: $dockerfilePath"
            Write-Host "Please ensure 'Dockerfile.IMPACTncdGER' exists in the docker_setup folder of your repository."
            Exit 1
        }

        # Build the Docker image
        Write-Host "[INFO] Building Docker image '$DockerImageName'..." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "This may take several minutes depending on the image size and dependencies..."
        Write-Host ""

        try {
            # Start timing the build process
            $buildStartTime = Get-Date
            Write-Host "[INFO] Docker build started at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "[INFO] This process may take 5-15 minutes depending on your system and network speed..." -ForegroundColor Cyan
            Write-Host ""
            Write-Host "[INFO] Build output will be shown below (this indicates progress):" -ForegroundColor Cyan
            Write-Host ("=" * 80)

            if ($CONTAINER_LOCATION -eq "LOCAL") { 
                # Local build with real-time output using direct execution
                Write-Host ""
                Write-Host "[BUILD] Starting local Docker build..."
                Write-Host ""

                # Build the Docker command as a single string for cmd /c execution
                $dockerCommand = "docker build -f `"$dockerfilePath`" -t $DockerImageName --no-cache --progress=plain `"$dockerContextPath`""
                Write-Debug-Message "[DEBUG] Docker command: $dockerCommand"
                Write-Host ""

                # Execute Docker build with real-time output
                Write-Host "[INFO] Building Docker image (this may take 5-15 minutes)..." -ForegroundColor Cyan
                Write-Host "[INFO] Docker build output (real-time):" -ForegroundColor Cyan
                Write-Host ("-" * 60)
                Write-Host "[DOCKER BUILD OUTPUT]" -ForegroundColor Blue
                
                try {
                    # Execute Docker build with direct console output (no redirection)
                    Write-Debug-Message "[DEBUG] Starting Docker build process with direct console streaming"
                    
                    # Use Start-Process without output redirection for true real-time display
                    # This allows Docker to write directly to the console
                    $arguments = @(
                        "build"
                        "-f"
                        "`"$dockerfilePath`""
                        "-t"
                        $DockerImageName
                        "--no-cache"
                        "--progress=plain"
                        "`"$dockerContextPath`""
                    )
                    
                    Write-Debug-Message "[DEBUG] Docker arguments: $($arguments -join ' ')"
                    
                    # Start the process with direct console output (no redirection)
                    $process = Start-Process -FilePath "docker" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
                    
                    $buildSuccess = $process.ExitCode -eq 0
                    
                    Write-Host ("-" * 60)
                    if ($buildSuccess) {
                        Write-Host "[SUCCESS] Docker build completed successfully!" -ForegroundColor Green
                        $buildResult = "Build process completed successfully with exit code: 0"
                    } else {
                        Write-Host "[FAILED] Docker build failed!" -ForegroundColor Red
                        $buildResult = "Build process failed with exit code: $($process.ExitCode)"
                    }
                    Write-Host ""
                } catch {
                    Write-Host ("-" * 60)
                    Write-Host "[ERROR] Exception during Docker build: $($_.Exception.Message)" -ForegroundColor Red
                    $buildSuccess = $false
                    $buildResult = "Build failed with exception: $($_.Exception.Message)"
                }

                Write-Host ("-" * 60)
                Write-Host ""

            } else {
                # Remote build with real-time output via SSH
                Write-Host ""
                Write-Host "[BUILD] Starting remote Docker build via SSH..."
                Write-Host ""
                $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                $buildCommand = "cd '$dockerContextPath' && docker buildx build -f '$dockerfilePath' -t '$DockerImageName' --no-cache --progress=plain . 2>&1"
                Write-Host ""

                # Execute remote Docker build with real-time output
                Write-Host "[INFO] Building Docker image on remote host (this may take 5-15 minutes)..." -ForegroundColor Cyan
                Write-Host "[INFO] Remote Docker build output (real-time):" -ForegroundColor Cyan
                Write-Host ("-" * 60)
                Write-Host "[DOCKER BUILD OUTPUT]" -ForegroundColor Blue

                try {
                    # Execute SSH command with direct console output (no redirection)
                    Set-DockerSSHEnvironment
                    $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                    Write-Debug-Message "[DEBUG] SSH command for remote build with direct console streaming"

                    # Use Start-Process for SSH without output redirection for true real-time display
                    $sshArguments = @(
                        "-o", "ConnectTimeout=30"
                        "-o", "BatchMode=yes"
                        "-o", "PasswordAuthentication=no"
                        "-o", "PubkeyAuthentication=yes"
                        "-o", "IdentitiesOnly=yes"
                        "-i", "`"$sshKeyPath`""
                        $remoteHost
                        "`"$buildCommand`""
                    )
                    
                    Write-Debug-Message "[DEBUG] SSH arguments: $($sshArguments -join ' ')"
                    
                    # Start the SSH process with direct console output (no redirection)
                    $process = Start-Process -FilePath "ssh" -ArgumentList $sshArguments -Wait -PassThru -NoNewWindow
                    
                    $buildSuccess = $process.ExitCode -eq 0
                    
                    Write-Host ("-" * 60)
                    if ($buildSuccess) {
                        Write-Host "[SUCCESS] Remote Docker build completed successfully!" -ForegroundColor Green
                        $buildResult = "Remote build process completed successfully with exit code: 0"
                    } else {
                        Write-Host "[FAILED] Remote Docker build failed!" -ForegroundColor Red
                        $buildResult = "Remote build process failed with exit code: $($process.ExitCode)"
                    }
                    Write-Host ""
                } catch {
                    Write-Host ("-" * 60)
                    Write-Host "[ERROR] Exception during remote Docker build: $($_.Exception.Message)" -ForegroundColor Red
                    $buildSuccess = $false
                    $buildResult = "Remote build failed with exception: $($_.Exception.Message)"
                }

                Write-Host ("-" * 60)
                Write-Host ""
            }

            $buildEndTime = Get-Date
            $totalElapsed = $buildEndTime - $buildStartTime
            Write-Host ("=" * 80)
            Write-Host "[INFO] Docker build completed at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "[INFO] Total build time: $("{0:mm\:ss}" -f $totalElapsed)" -ForegroundColor Cyan
            Write-Host ""

            if ($buildSuccess) {
                Write-Host "[SUCCESS] Docker image '$DockerImageName' built successfully!" -ForegroundColor Green
                Write-Host ""
            } else {
                Write-Host "[WARNING] Failed to build Docker image '$DockerImageName' on first attempt" -ForegroundColor Yellow
                Write-Host "Build output:"
                Write-Host $buildResult
                Write-Host ""
                Write-Host "[INFO] Attempting fallback: building prerequisite image first..." -ForegroundColor Cyan
                Write-Host ""

                # Determine prerequisite Dockerfile path and build context (this time docker_setup folder)
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    $prereqDockerfilePath = Join-Path $script:LocalRepoPath "docker_setup\Dockerfile.prerequisite.IMPACTncdGER"
                    $prereqDockerContextPath = Join-Path $script:LocalRepoPath "docker_setup"

                } else {
                    $prereqDockerfilePath = "$script:RemoteRepoPath/docker_setup/Dockerfile.prerequisite.IMPACTncdGER"
                    $prereqDockerContextPath = "$script:RemoteRepoPath/docker_setup"
                }

                Write-Host "[INFO] Using prerequisite Dockerfile: $prereqDockerfilePath" -ForegroundColor Cyan
                Write-Host ""

                # Check if prerequisite Dockerfile exists
                $prereqDockerfileExists = $false
                try {
                    if ($CONTAINER_LOCATION -eq "LOCAL") {
                        $prereqDockerfileExists = Test-Path $prereqDockerfilePath
                    } else {
                        $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                        $prereqDockerfileCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "test -f '$prereqDockerfilePath' && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1
                        $prereqDockerfileExists = $prereqDockerfileCheck -match "EXISTS"
                    }
                } catch {
                    Write-Host "[ERROR] Could not check for prerequisite Dockerfile: $($_.Exception.Message)" -ForegroundColor Red
                    Write-Host ""
                    $prereqDockerfileExists = $false
                }

                if ($prereqDockerfileExists) {
                    Write-Host "[INFO] Building prerequisite Docker image..." -ForegroundColor Cyan
                    Write-Host ""
                    Write-Host "[INFO] This may take 3-10 minutes for the prerequisite image..." -ForegroundColor Cyan
                    Write-Host ""
                    $prereqImageName = "$DockerImageName-prerequisite"

                    try {
                        # Start timing the prerequisite build
                        $prereqStartTime = Get-Date
                        Write-Host "[PREREQ] Prerequisite build started at $(Get-Date -Format 'HH:mm:ss')"
                        Write-Host ("=" * 60)

                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            # Local build of prerequisite with real-time output
                            Write-Host "[DOCKER-PREREQ] Building prerequisite image locally..."
                            Write-Host ""

                            # Build the Docker command for prerequisite
                            $prereqCommand = "docker build -f `"$prereqDockerfilePath`" -t $prereqImageName --no-cache --progress=plain `"$prereqDockerContextPath`""
                            Write-Debug-Message "[DEBUG] Prerequisite command: $prereqCommand"
                            # Execute prerequisite build with real-time output
                            Write-Host "[INFO] Building prerequisite image (this may take 5-15 minutes)..." -ForegroundColor Cyan
                            Write-Host "[INFO] Prerequisite build output (real-time):" -ForegroundColor Cyan
                            Write-Host ("-" * 60)
                            Write-Host "[DOCKER PREREQUISITE BUILD OUTPUT]" -ForegroundColor Blue

                            try {
                                # Execute prerequisite build with direct console output
                                Write-Debug-Message "[DEBUG] Starting prerequisite build with direct console streaming"
                                
                                # Use Start-Process without output redirection for true real-time display
                                $dockerArguments = @(
                                    "build"
                                    "-f", "`"$prereqDockerfilePath`""
                                    "-t", $prereqImageName
                                    "--no-cache"
                                    "--progress=plain"
                                    "`"$prereqDockerContextPath`""
                                )
                                
                                Write-Debug-Message "[DEBUG] Docker prerequisite arguments: $($dockerArguments -join ' ')"
                                
                                # Start the Docker process with direct console output
                                $process = Start-Process -FilePath "docker" -ArgumentList $dockerArguments -Wait -PassThru -NoNewWindow
                                
                                $prereqBuildSuccess = $process.ExitCode -eq 0
                                Get-EventSubscriber | Where-Object { $_.SourceObject -eq $process } | Unregister-Event
                                
                                Write-Host ("-" * 60)
                                if ($prereqBuildSuccess) {
                                    Write-Host "[SUCCESS] Prerequisite build completed successfully!" -ForegroundColor Green
                                    $prereqBuildResult = "Prerequisite build process completed successfully with exit code: 0"
                                } else {
                                    Write-Host "[FAILED] Prerequisite build failed!" -ForegroundColor Red
                                    $prereqBuildResult = "Prerequisite build process failed with exit code: $($process.ExitCode)"
                                }
                                Write-Host ""
                            } catch {
                                Write-Host ("-" * 60)
                                Write-Host "[ERROR] Exception during prerequisite build: $($_.Exception.Message)" -ForegroundColor Red
                                $prereqBuildSuccess = $false
                                $prereqBuildResult = "Prerequisite build failed with exception: $($_.Exception.Message)"
                            }

                            Write-Host ("-" * 60)
                            Write-Host ""

                        } else {
                            # Remote build of prerequisite with real-time output
                            Write-Host "[DOCKER-PREREQ] Building prerequisite image on remote host..."
                            $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                            $prereqBuildCommand = "cd '$prereqDockerContextPath' && docker buildx build -f '$prereqDockerfilePath' -t '$prereqImageName' --no-cache --progress=plain . 2>&1"

                            # Execute remote prerequisite build with real-time output
                            Write-Host "[INFO] Building prerequisite image on remote host (this may take 5-15 minutes)..." -ForegroundColor Cyan
                            Write-Host "[INFO] Remote prerequisite build output (real-time):" -ForegroundColor Cyan
                            Write-Host ("-" * 60)
                            Write-Host "[DOCKER PREREQUISITE BUILD OUTPUT]" -ForegroundColor Blue

                            try {
                                # Execute SSH prerequisite command with direct console output
                                Set-DockerSSHEnvironment
                                $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                                Write-Debug-Message "[DEBUG] SSH prerequisite command for remote build with direct console streaming"

                                # Use Start-Process for SSH prerequisite without output redirection
                                $sshArguments = @(
                                    "-o", "ConnectTimeout=30"
                                    "-o", "BatchMode=yes"
                                    "-o", "PasswordAuthentication=no"
                                    "-o", "PubkeyAuthentication=yes"
                                    "-o", "IdentitiesOnly=yes"
                                    "-i", "`"$sshKeyPath`""
                                    $remoteHost
                                    "`"$prereqBuildCommand`""
                                )
                                
                                Write-Debug-Message "[DEBUG] SSH prerequisite arguments: $($sshArguments -join ' ')"
                                
                                # Start the SSH process with direct console output
                                $process = Start-Process -FilePath "ssh" -ArgumentList $sshArguments -Wait -PassThru -NoNewWindow
                                
                                $prereqBuildSuccess = $process.ExitCode -eq 0
                                
                                Write-Host ("-" * 60)
                                if ($prereqBuildSuccess) {
                                    Write-Host "[SUCCESS] Remote prerequisite build completed successfully!" -ForegroundColor Green
                                    $prereqBuildResult = "Remote prerequisite build process completed successfully with exit code: 0"
                                } else {
                                    Write-Host "[FAILED] Remote prerequisite build failed!" -ForegroundColor Red
                                    $prereqBuildResult = "Remote prerequisite build process failed with exit code: $($process.ExitCode)"
                                }
                                Write-Host ""
                            } catch {
                                Write-Host ("-" * 60)
                                Write-Host "[ERROR] Exception during remote prerequisite build: $($_.Exception.Message)" -ForegroundColor Red
                                $prereqBuildSuccess = $false
                                $prereqBuildResult = "Remote prerequisite build failed with exception: $($_.Exception.Message)"
                            }

                            Write-Host ("-" * 60)
                            Write-Host ""
                        }

                        $prereqEndTime = Get-Date
                        $prereqElapsed = $prereqEndTime - $prereqStartTime
                        Write-Host ("=" * 60)
                        Write-Host "[DOCKER-PREREQ] Prerequisite build completed in $("{0:mm\:ss}" -f $prereqElapsed)"
                        Write-Host ""

                        if ($prereqBuildSuccess) {
                            Write-Host "[SUCCESS] Prerequisite image built successfully! Retrying main image build..." -ForegroundColor Green

                            # Retry building the main image TODO: Add logic that it does not try to build from kalleef account but uses the local prereq image!
                            try {
                                # Start timing the retry build
                                $retryStartTime = Get-Date
                                Write-Host "[DOCKER-RETRY] Main image retry build started at $(Get-Date -Format 'HH:mm:ss')"
                                Write-Host ""
                                Write-Host "[DOCKER-RETRY] This should be faster now that prerequisite is built..."
                                Write-Host ("=" * 60)

                                if ($CONTAINER_LOCATION -eq "LOCAL") {
                                    # Local build retry with real-time output
                                    Write-Host "[DOCKER-RETRY] Retrying main image build locally..."
                                    Write-Host ""

                                    # Build the Docker command for retry
                                    $retryCommand = "docker build -f `"$dockerfilePath`" -t $DockerImageName --no-cache --progress=plain `"$dockerContextPath`""
                                    Write-Debug-Message "[DEBUG] Retry command: $retryCommand"
                                    Write-Host ""

                                    # Execute retry build with real-time output
                                    Write-Host "[INFO] Retrying main image build (should be faster with prerequisite)..." -ForegroundColor Cyan
                                    Write-Host "[INFO] Retry build output (real-time):" -ForegroundColor Cyan
                                    Write-Host ("-" * 60)
                                    Write-Host "[DOCKER RETRY BUILD OUTPUT]" -ForegroundColor Blue

                                    try {
                                        # Execute retry build with direct console output
                                        Write-Debug-Message "[DEBUG] Starting retry build with direct console streaming"
                                        
                                        # Use Start-Process without output redirection for true real-time display
                                        $dockerArguments = @(
                                            "build"
                                            "-f", "`"$dockerfilePath`""
                                            "-t", $DockerImageName
                                            "--no-cache"
                                            "--progress=plain"
                                            "`"$dockerContextPath`""
                                        )
                                        
                                        Write-Debug-Message "[DEBUG] Docker retry arguments: $($dockerArguments -join ' ')"
                                        
                                        # Start the Docker process with direct console output
                                        $process = Start-Process -FilePath "docker" -ArgumentList $dockerArguments -Wait -PassThru -NoNewWindow
                                        
                                        $retryBuildSuccess = $process.ExitCode -eq 0
                                        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $process } | Unregister-Event
                                        
                                        Write-Host ("-" * 60)
                                        if ($retryBuildSuccess) {
                                            Write-Host "[SUCCESS] Retry build completed successfully!" -ForegroundColor Green
                                            $retryBuildResult = "Retry build process completed successfully with exit code: 0"
                                        } else {
                                            Write-Host "[FAILED] Retry build failed!" -ForegroundColor Red
                                            $retryBuildResult = "Retry build process failed with exit code: $($process.ExitCode)"
                                        }
                                        Write-Host ""
                                    } catch {
                                        Write-Host ("-" * 60)
                                        Write-Host "[ERROR] Exception during retry build: $($_.Exception.Message)" -ForegroundColor Red
                                        $retryBuildSuccess = $false
                                        $retryBuildResult = "Retry build failed with exception: $($_.Exception.Message)"
                                    }

                                    Write-Host ("-" * 60)
                                    Write-Host ""

                                } else {
                                    # Remote build retry with real-time output
                                    Write-Host "[DOCKER-RETRY-REMOTE] Retrying main image build on remote host..."
                                    $remoteHost = "php-workstation@$($script:RemoteHostIp)"
                                    $retryBuildCommand = "cd '$dockerContextPath' && docker buildx build -f '$dockerfilePath' -t '$DockerImageName' --no-cache --progress=plain . 2>&1"

                                    # Execute remote retry build with real-time output
                                    Write-Host "[INFO] Retrying main image build on remote host (should be faster with prerequisite)..." -ForegroundColor Cyan
                                    Write-Host "[INFO] Remote retry build output (real-time):" -ForegroundColor Cyan
                                    Write-Host ("-" * 60)
                                    Write-Host "[DOCKER RETRY BUILD OUTPUT]" -ForegroundColor Blue

                                    try {
                                        # Execute SSH retry command with direct console output
                                        Set-DockerSSHEnvironment
                                        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                                        Write-Debug-Message "[DEBUG] SSH retry command for remote build with direct console streaming"

                                        # Use Start-Process for SSH retry without output redirection
                                        $sshArguments = @(
                                            "-o", "ConnectTimeout=30"
                                            "-o", "BatchMode=yes"
                                            "-o", "PasswordAuthentication=no"
                                            "-o", "PubkeyAuthentication=yes"
                                            "-o", "IdentitiesOnly=yes"
                                            "-i", "`"$sshKeyPath`""
                                            $remoteHost
                                            "`"$retryBuildCommand`""
                                        )
                                        
                                        Write-Debug-Message "[DEBUG] SSH retry arguments: $($sshArguments -join ' ')"
                                        
                                        # Start the SSH process with direct console output
                                        $process = Start-Process -FilePath "ssh" -ArgumentList $sshArguments -Wait -PassThru -NoNewWindow
                                        
                                        $retryBuildSuccess = $process.ExitCode -eq 0
                                        Get-EventSubscriber | Where-Object { $_.SourceObject -eq $process } | Unregister-Event
                                        
                                        Write-Host ("-" * 60)
                                        if ($retryBuildSuccess) {
                                            Write-Host "[SUCCESS] Remote retry build completed successfully!" -ForegroundColor Green
                                            $retryBuildResult = "Remote retry build process completed successfully with exit code: 0"
                                        } else {
                                            Write-Host "[FAILED] Remote retry build failed!" -ForegroundColor Red
                                            $retryBuildResult = "Remote retry build process failed with exit code: $($process.ExitCode)"
                                        }
                                        Write-Host ""
                                    } catch {
                                        Write-Host ("-" * 60)
                                        Write-Host "[ERROR] Exception during remote retry build: $($_.Exception.Message)" -ForegroundColor Red
                                        $retryBuildSuccess = $false
                                        $retryBuildResult = "Remote retry build failed with exception: $($_.Exception.Message)"
                                    }

                                    Write-Host ("-" * 60)
                                    Write-Host ""
                                }

                                $retryEndTime = Get-Date
                                $retryElapsed = $retryEndTime - $retryStartTime
                                Write-Host ("=" * 60)
                                Write-Host "[DOCKER-RETRY] Retry build completed in $("{0:mm\:ss}" -f $retryElapsed)"

                                if ($retryBuildSuccess) {
                                    Write-Host ""
                                    Write-Host "[SUCCESS] Docker image '$DockerImageName' built successfully after prerequisite build!" -ForegroundColor Green
                                } else {
                                    Write-Host ""
                                    Write-Host "[ERROR] Failed to build Docker image '$DockerImageName' even after building prerequisite" -ForegroundColor Red
                                    Write-Host ""
                                    Write-Host "Retry build output:"
                                    Write-Host $retryBuildResult
                                    Exit 1
                                }
                            } catch {
                                Write-Host ""
                                Write-Host "[ERROR] Exception occurred during retry build: $($_.Exception.Message)" -ForegroundColor Red
                                Exit 1
                            }
                        } else {
                            Write-Host "[ERROR] Failed to build prerequisite Docker image" -ForegroundColor Red
                            Write-Host ""
                            Write-Host "Prerequisite build output:"
                            Write-Host $prereqBuildResult
                            Exit 1
                        }
                    } catch {
                        Write-Host ""
                        Write-Host "[ERROR] Exception occurred while building prerequisite image: $($_.Exception.Message)" -ForegroundColor Red
                        Exit 1
                    }
                } else {
                    Write-Host ""
                    Write-Host "[ERROR] Prerequisite Dockerfile not found at: $prereqDockerfilePath" -ForegroundColor Red
                    Write-Host ""
                    Write-Host "[FATAL ERROR] Cannot build Docker image - both main and prerequisite Dockerfiles failed"
                    Exit 1
                }
            }
        } catch {
            Write-Host ""
            Write-Host "[ERROR] Exception occurred while building Docker image: $($_.Exception.Message)" -ForegroundColor Red
            Exit 1
        }
    }

    # Capture git state before starting container for change detection
    Write-Host "[INFO] Capturing git state for change detection..." -ForegroundColor Cyan
    
    # Determine which repository path to use for git operations
    if ($CONTAINER_LOCATION -eq "LOCAL" -and $script:LocalRepoPath) {
        $gitRepoPath = $script:LocalRepoPath
        Write-Host "[INFO] Using local repository path for git operations: $gitRepoPath" -ForegroundColor Cyan
    } elseif ($CONTAINER_LOCATION -like "REMOTE@*" -and $script:RemoteRepoPath) {
        $gitRepoPath = $script:RemoteRepoPath
        Write-Host "[INFO] Using remote repository path for git operations: $gitRepoPath" -ForegroundColor Cyan
    } else {
        Write-Host "[WARNING] No valid repository path found for git operations" -ForegroundColor Yellow
        $gitRepoPath = $null
    }
    
    if ($gitRepoPath) {
        $script:GitStateBeforeContainer = Get-GitRepositoryState -RepoPath $gitRepoPath -Pull
        $script:GitRepoPath = $gitRepoPath  # Store for later use in stop handler
    } else {
        $script:GitStateBeforeContainer = $null
        $script:GitRepoPath = $null
    }
    Write-Host ""

    #-------------------------------------------------------#
    #    Prepare directories and Docker mounts if needed    #
    #-------------------------------------------------------#

    # Use current user (for user-specific volume names)
    # Sanitize username for Docker volume names (replace spaces and special characters with underscores)
    $SafeCurrentUser = $USERNAME -replace '[^a-zA-Z0-9]', '_' -replace '__+', '_' -replace '^_|_$', ''
    if ([string]::IsNullOrEmpty($SafeCurrentUser)) {
        $SafeCurrentUser = "dockeruser"
        Write-Host "[WARNING] Could not determine a valid username, using fallback: $SafeCurrentUser" -ForegroundColor Yellow
    }

    # Get user identity information for non-root Docker execution
    # Note: On Windows, Docker Desktop runs containers in a Linux VM, so we use
    # default UID/GID (1000:1000) which works well for most cases
    $script:UserId = 1000 #TODO: Check SSH user implementation to avoid root access? See ChatGPT suggestions.
    $script:GroupId = 1000
    $UserId = $script:UserId   # Keep local copy for backwards compatibility
    $GroupId = $script:GroupId # Keep local copy for backwards compatibility

    # Define user-specific Docker volume names using sanitized username (only for output and synthpop)
    $script:VolumeOutput = "impactncd_germany_output_$SafeCurrentUser"
    $script:VolumeSynthpop = "impactncd_germany_synthpop_$SafeCurrentUser"
    $VolumeOutput = $script:VolumeOutput     # Keep local copy for backwards compatibility
    $VolumeSynthpop = $script:VolumeSynthpop # Keep local copy for backwards compatibility

    # TODO: Logic for synthpop and output folders on local and remote POTENTIAL IMPLICATIONS FOR USER CREATION ETC!    
    # Replace backwards with forward slashes in ProjectRoot for Docker compatibility
    $ProjectRoot = $ProjectRoot -replace '\\', '/'

    # Call the function passing $ProjectRoot
    Write-Host ""
    Write-Host ""
    $script:OutputDir = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "output_dir" -BaseDir $ProjectRoot
    $outputDir = $script:OutputDir  # Keep local copy for backwards compatibility
    Write-Host ""
    Write-Host ""
    $script:SynthpopDir = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "synthpop_dir" -BaseDir $ProjectRoot
    $synthpopDir = $script:SynthpopDir  # Keep local copy for backwards compatibility
    Write-Host ""
    Write-Host ""


    # Validate or create output directory
    if (-not (Test-AndCreateDirectory -Path $outputDir -PathKey "output_dir")) {
        Write-Host "[FATAL ERROR] Failed to create output directory: $outputDir"
        Write-Host ""
        Write-Host "Please check your sim_design.yaml file and ensure the path is valid."
        Exit 1
    }

    # Validate or create synthpop directory
    if (-not (Test-AndCreateDirectory -Path $synthpopDir -PathKey "synthpop_dir")) {
        Write-Host "[FATAL ERROR] Failed to create synthpop directory: $synthpopDir"
        Write-Host ""
        Write-Host "Please check your sim_design.yaml file and ensure the path is valid."
        Exit 1
    }

    Write-Host "[INFO] Mounting output_dir to container ($CONTAINER_NAME):    $outputDir" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ""       # Keep using forward slashes for Docker mounts
    Write-Host "[INFO] Mounting synthpop_dir to container ($CONTAINER_NAME):  $synthpopDir" -ForegroundColor Cyan
    Write-Host ""
    Write-Host ""       # Keep using forward slashes for Docker mounts

    #-------------------------------------#
    #   Run the actual Docker container   #
    #-------------------------------------#
    
    # For remote operations, verify SSH key files exist before proceeding
    if ($CONTAINER_LOCATION -ne "LOCAL") {
        Write-Host "[INFO] Verifying SSH key files exist on remote system for Docker mounting..." -ForegroundColor Cyan
        
        $sshKeyVerification = Test-RemoteSSHKeyFiles -RemoteHost $remoteHost -Username $USERNAME
        
        if ($sshKeyVerification.PrivateKeyExists -and $sshKeyVerification.KnownHostsExists) {
            Write-Host "  [SUCCESS] All SSH files verified for Docker container mounting" -ForegroundColor Green
        } else {
            Write-Host "  [ERROR] SSH key files are not properly set up on the remote system!" -ForegroundColor Red
            
            foreach ($errorDetail in $sshKeyVerification.ErrorDetails) {
                Write-Host "    [ERROR] $errorDetail" -ForegroundColor Red
            }
            
            Write-Host ""
            Write-Host "[FATAL ERROR] Cannot proceed with Docker container creation!" -ForegroundColor Red
            Write-Host ""
            Write-Host "To fix this issue:" -ForegroundColor Yellow
            Write-Host "1. Re-run this script and complete the SSH authentication step" -ForegroundColor Yellow
            Write-Host "2. Ensure the private key copying step completed successfully" -ForegroundColor Yellow
            Write-Host "3. Check that the remote system has sufficient disk space" -ForegroundColor Yellow
            Write-Host "4. Verify the remote .ssh directory has correct permissions (700)" -ForegroundColor Yellow
            Write-Host ""
            Exit 1
        }
        Write-Host ""
    }
    
    if ($useVolumes) {
        Write-Host "[INFO] Using Docker volumes for outputs and synthpop..." -ForegroundColor Cyan
        
        # Configure SSH key paths based on execution location
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            # Configure SSH key paths for Windows
            $sshKeyPath = "${HOME}\.ssh\id_ed25519_${USERNAME}"
            $knownHostsPath = "${HOME}\.ssh\known_hosts"
        } else {
            # Configure SSH key paths for Linux (remote host)
            $sshKeyPath = "/home/php-workstation/.ssh/id_ed25519_${USERNAME}"
            $knownHostsPath = "/home/php-workstation/.ssh/known_hosts"
        }
        
        # Build rsync-alpine image if it doesn't already exist.
        $script:RsyncImage = "rsync-alpine"
        $rsyncImage = $script:RsyncImage  # Keep local copy for backwards compatibility
        
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker image inspect $rsyncImage > $null 2>&1
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName image inspect $rsyncImage > $null 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[INFO] Building rsync-alpine image..." -ForegroundColor Cyan

            # Use inline Dockerfile approach for reliable cross-platform building
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                Write-Host "[INFO] Creating rsync image inline for local Docker..." -ForegroundColor Cyan
                $InlineDockerfile = @"
FROM alpine:latest
RUN apk add --no-cache rsync
"@
                $InlineDockerfile | & docker build -t $rsyncImage -
            } else {
                Write-Host "[INFO] Creating rsync image inline for remote Docker..." -ForegroundColor Cyan
                Set-DockerSSHEnvironment
                $InlineDockerfile = @"
FROM alpine:latest
RUN apk add --no-cache rsync
"@
                $InlineDockerfile | & docker --context $script:RemoteContextName build -t $rsyncImage -
            }
        } else {
            Write-Host "[INFO] Using existing rsync-alpine image." -ForegroundColor Cyan
        }

        # Ensure output directories exist (only needed for local operations since remote is handled by Test-AndCreateDirectory)
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
            if (-not (Test-Path $synthpopDir)) { New-Item -ItemType Directory -Path $synthpopDir | Out-Null }
        }

        # Remove any existing volumes (ignore errors if not removable)
        Write-Host "[INFO] Removing any existing volumes (if possible)..." -ForegroundColor Cyan
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker volume rm $VolumeOutput -f 2>$null
            & docker volume rm $VolumeSynthpop -f 2>$null
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName volume rm $VolumeOutput -f 2>$null
            & docker --context $script:RemoteContextName volume rm $VolumeSynthpop -f 2>$null
        }

        # Create fresh Docker-managed volumes
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker volume create $VolumeOutput | Out-Null
            & docker volume create $VolumeSynthpop | Out-Null
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName volume create $VolumeOutput | Out-Null
            & docker --context $script:RemoteContextName volume create $VolumeSynthpop | Out-Null
        }

        # Fix volume ownership and pre-populate volumes:
        # Docker volumes are created with root ownership by default. We need to fix
        # the ownership before we can populate them as the calling user.
        Write-Debug-Message "[DEBUG] Starting Docker volume ownership configuration..."
        Write-Debug-Message "[DEBUG] Target User ID: $UserId, Group ID: $GroupId"
        Write-Host "[INFO] Setting correct ownership for Docker volumes..." -ForegroundColor Cyan
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            Write-Debug-Message "[DEBUG] Setting local Docker volume ownership..."
            & docker run --rm -v "${VolumeOutput}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
            & docker run --rm -v "${VolumeSynthpop}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
            Write-Debug-Message "[DEBUG] Local volume ownership set successfully"
        } else {
            Write-Debug-Message "[DEBUG] Setting remote Docker volume ownership using context: $script:RemoteContextName"
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName run --rm -v "${VolumeOutput}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
            & docker --context $script:RemoteContextName run --rm -v "${VolumeSynthpop}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
            Write-Debug-Message "[DEBUG] Remote volume ownership set successfully"
        }
        Write-Host ""

        # Pre-populate volumes:
        # The output and synthpop volumes are populated from the respective source folders.
        Write-Debug-Message "[DEBUG] Starting volume pre-population process..."
        
        # Use permission-tolerant copy with fallback logic
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            Write-Debug-Message "[DEBUG] Configuring local Docker paths..."
            # For local Windows, convert paths for Docker
            $dockerOutputSource = Convert-PathToDockerFormat -Path $outputDir
            $dockerSynthpopSource = Convert-PathToDockerFormat -Path $synthpopDir
            $script:RepoPath = $script:LocalRepoPath
            Write-Debug-Message "[DEBUG] Local Docker output source: $dockerOutputSource"
            Write-Debug-Message "[DEBUG] Local Docker synthpop source: $dockerSynthpopSource"
        } else {
            Write-Debug-Message "[DEBUG] Configuring remote Docker paths..."
            # For remote Linux, use paths directly
            $dockerOutputSource = $outputDir
            $dockerSynthpopSource = $synthpopDir
            $script:RepoPath = $script:RemoteRepoPath
            Write-Debug-Message "[DEBUG] Remote Docker output source: $dockerOutputSource"
            Write-Debug-Message "[DEBUG] Remote Docker synthpop source: $dockerSynthpopSource"
        }

        Write-Host "[INFO] Populating output volume from source directory..." -ForegroundColor Cyan
        Write-Host ""
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker run --rm --user "${UserId}:${GroupId}" -v "${dockerOutputSource}:/source" -v "${VolumeOutput}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName run --rm --user "${UserId}:${GroupId}" -v "${dockerOutputSource}:/source" -v "${VolumeOutput}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        }
        Write-Host "[INFO] Populating synthpop volume from source directory..." -ForegroundColor Cyan
        Write-Host ""
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker run --rm --user "${UserId}:${GroupId}" -v "${dockerSynthpopSource}:/source" -v "${VolumeSynthpop}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName run --rm --user "${UserId}:${GroupId}" -v "${dockerSynthpopSource}:/source" -v "${VolumeSynthpop}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        }

        # Run the main container with volumes mounted.
        Write-Host "[INFO] Running the main container using Docker volumes..." -ForegroundColor Cyan
        # Construct arguments as an array for reliable passing
        $dockerArgs = @(
            "run", "-d", "--rm",     
            # User identity environment variables
            "--name", "$CONTAINER_NAME",
            "-e", "GIT_SSH_COMMAND=ssh -i /keys/id_ed25519_${USERNAME} -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
            "-e", "GIT_KEY_PATH=/keys/id_ed25519_${USERNAME}",
            "-e", "USERID=$UserId",
            "-e", "GROUPID=$GroupId",
            "-e", "PASSWORD=$PASSWORD",
            "-e", "DISABLE_AUTH=false",
            # Repo sync settings to update container based on changes
            "--mount", "type=bind,source=$script:RepoPath,target=/host-repo",
            "-e", "REPO_SYNC_PATH=/host-repo",
            "-e", "SYNC_ENABLED=true",
            # Port mapping with override support
            "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
            # Directory mounts
            "-v", "${VolumeOutput}:/home/rstudio/$script:SelectedRepo/outputs",
            "-v", "${VolumeSynthpop}:/home/rstudio/$script:SelectedRepo/inputs/synthpop",
            # SSH key and known_hosts for git access - use appropriate paths for execution location
            "--mount", "type=bind,source=${sshKeyPath},target=/keys/id_ed25519_${USERNAME},readonly",
            "--mount", "type=bind,source=${knownHostsPath},target=/etc/ssh/ssh_known_hosts,readonly",
            # Working directory
            "--workdir", "/home/rstudio/$script:SelectedRepo"
        )
        
        # Add computational resource limits for remote high-demand containers
        if ($CONTAINER_LOCATION -ne "LOCAL" -and $highComputeDemand) {
            Write-Host "[INFO] Applying high computational resource limits for remote container..." -ForegroundColor Cyan
            $dockerArgs += "--cpus"
            $dockerArgs += "32"  # Limit to 32 CPU cores
            $dockerArgs += "-m"
            $dockerArgs += "384g"  # Limit to 384GB memory
            Write-Host "  CPU Limit: 32 cores" -ForegroundColor Cyan
            Write-Host "  Memory Limit: 384GB" -ForegroundColor Cyan
            Write-Host ""
        }
        
        # Add customParams if specified
        #if ($null -ne $customParams) {
        #    $customParamsArray = $customParams -split '\s+'
        #    $dockerArgs += $customParamsArray
        #}

        # Add final argument
        $dockerArgs += $DockerImageName

        # Execute docker with the arguments array
        Write-Host "[INFO] Starting RStudio Server container with volumes..." -ForegroundColor Cyan
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker $dockerArgs
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName $dockerArgs
        }
        Write-Host ""
        Write-Host ""
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[SUCCESS] RStudio Server container started successfully!" -ForegroundColor Green
            Write-Host ""
            
            # Wait a moment for the container to fully start
            Write-Host "[INFO] Waiting for RStudio Server to initialize..." -ForegroundColor Cyan
            Start-Sleep -Seconds 3
            
            # Check if container is still running
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $containerStatus = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
            } else {
                Set-DockerSSHEnvironment
                $containerStatus = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
            }
            if ($containerStatus) {
                Write-Host "[SUCCESS] Container is running: $containerStatus" -ForegroundColor Green
                Write-Host ""
                Write-Host "==============================================="
                Write-Host "  RStudio Server Access Information"
                Write-Host "==============================================="
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    Write-Host "  URL: http://localhost:$(if($portOverride) { $portOverride } else { '8787' })"
                } else {
                    Write-Host "  URL: http://$($script:RemoteHostIp):$(if($portOverride) { $portOverride } else { '8787' })"
                }
                Write-Host "  Username: rstudio"
                Write-Host "  Password: $PASSWORD"
                Write-Host ""
                Write-Host "  Container Name: $CONTAINER_NAME"
                Write-Host "  Execution Location: $CONTAINER_LOCATION"
                Write-Host "  Using Docker Volumes: Yes"
                Write-Host "==============================================="
                Write-Host ""
                Write-Host "[INFO] Container is running in the background." -ForegroundColor Cyan
                Write-Host "[INFO] Use the 'Stop Container' button to stop it when done." -ForegroundColor Cyan
                
                # Update UI state - container started successfully
                $buttonStart.Enabled = $false
                $buttonStop.Enabled = $true
                Update-InstructionText -Status "RUNNING" -Location $CONTAINER_LOCATION -VolumesInfo "Enabled"
                
            } else {
                Write-Host "[WARNING] Container may have exited. Checking logs..." -ForegroundColor Yellow
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    $containerLogs = & docker logs $CONTAINER_NAME 2>&1
                } else {
                    Set-DockerSSHEnvironment
                    $containerLogs = & docker --context $script:RemoteContextName logs $CONTAINER_NAME 2>&1
                }
                Write-Host "[ERROR] Container logs:" -ForegroundColor Red
                Write-Host $containerLogs
                
                # Container failed to start properly - keep start button enabled
                Write-Host "[ERROR] Container failed to start properly. Please check the logs above." -ForegroundColor Red
            }
        } else {
            Write-Host "[ERROR] Failed to start RStudio Server container with volumes" -ForegroundColor Red
            Write-Host "Exit code: $LASTEXITCODE"
            Write-Host "Execution location: $CONTAINER_LOCATION"
        }

    } else {
        Write-Host "[INFO] Using direct bind mounts for outputs and synthpop..." -ForegroundColor Cyan
        Write-Host ""

        # Configure Docker arguments based on execution location (LOCAL vs REMOTE)
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            Write-Host "[INFO] Configuring Docker arguments for LOCAL Windows execution..." -ForegroundColor Cyan
            Write-Host ""

            # Convert paths for Docker bind mount (Windows to WSL format)
            $DockerOutputDir = Convert-PathToDockerFormat -Path $outputDir
            $DockerSynthpopDir = Convert-PathToDockerFormat -Path $synthpopDir
            
            Write-Host "[INFO] Docker Output Dir:   $DockerOutputDir" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "[INFO] Docker Synthpop Dir: $DockerSynthpopDir" -ForegroundColor Cyan
            Write-Host ""

            # Configure SSH key paths for Windows
            $sshKeyPath = "${HOME}\.ssh\id_ed25519_${USERNAME}"
            $knownHostsPath = "${HOME}\.ssh\known_hosts"
            
            $dockerArgs = @(
                "run", "-d", "--rm",     
                # User identity environment variables
                "--name", "$CONTAINER_NAME",
                "-e", "GIT_SSH_COMMAND=ssh -i /keys/id_ed25519_${USERNAME} -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
                "-e", "GIT_KEY_PATH=/keys/id_ed25519_${USERNAME}",
                "-e", "USERID=$UserId",
                "-e", "GROUPID=$GroupId",
                "-e", "PASSWORD=$PASSWORD",
                "-e", "DISABLE_AUTH=false",
                # Repo sync settings to update container based on changes
                "--mount", "type=bind,source=$script:LocalRepoPath,target=/host-repo",
                "-e", "REPO_SYNC_PATH=/host-repo",
                "-e", "SYNC_ENABLED=true",
                # Port mapping with override support
                "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
                # Directory mounts
                "--mount", "type=bind,source=$DockerOutputDir,target=/home/rstudio/$script:SelectedRepo/outputs",
                "--mount", "type=bind,source=$DockerSynthpopDir,target=/home/rstudio/$script:SelectedRepo/inputs/synthpop",
                # SSH key and known_hosts for git access (Windows paths)
                "--mount", "type=bind,source=${sshKeyPath},target=/keys/id_ed25519_${USERNAME},readonly",
                "--mount", "type=bind,source=${knownHostsPath},target=/etc/ssh/ssh_known_hosts,readonly",
                # Working directory
                "--workdir", "/home/rstudio/$script:SelectedRepo"
            )
            
        } else {
            Write-Host "[INFO] Configuring Docker arguments for REMOTE Linux execution..." -ForegroundColor Cyan
            Write-Host ""

            # For remote execution, paths are already in Unix format
            $DockerOutputDir = $outputDir
            $DockerSynthpopDir = $synthpopDir
            
            Write-Host "[INFO] Docker Output Dir:   $DockerOutputDir" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "[INFO] Docker Synthpop Dir: $DockerSynthpopDir" -ForegroundColor Cyan
            Write-Host ""
            
            # Configure SSH key paths for Linux (remote host)
            $sshKeyPath = "/home/php-workstation/.ssh/id_ed25519_${USERNAME}"
            $knownHostsPath = "/home/php-workstation/.ssh/known_hosts"
            
            $dockerArgs = @(
                "run", "-d", "--rm",     
                # User identity environment variables
                "--name", "$CONTAINER_NAME",
                "-e", "GIT_SSH_COMMAND=ssh -i /keys/id_ed25519_${USERNAME} -o IdentitiesOnly=yes -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts -o StrictHostKeyChecking=yes",
                "-e", "GIT_KEY_PATH=/keys/id_ed25519_${USERNAME}",
                "-e", "USERID=$UserId",
                "-e", "GROUPID=$GroupId",
                "-e", "PASSWORD=$PASSWORD",
                "-e", "DISABLE_AUTH=false",
                # Repo sync settings to update container based on changes
                "--mount", "type=bind,source=$script:RemoteRepoPath,target=/host-repo",
                "-e", "REPO_SYNC_PATH=/host-repo",
                "-e", "SYNC_ENABLED=true",
                # Port mapping with override support
                "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
                # Directory mounts (Unix paths)
                "--mount", "type=bind,source=$DockerOutputDir,target=/home/rstudio/$script:SelectedRepo/outputs",
                "--mount", "type=bind,source=$DockerSynthpopDir,target=/home/rstudio/$script:SelectedRepo/inputs/synthpop",
                # SSH key and known_hosts for git access (Linux paths)
                "--mount", "type=bind,source=${sshKeyPath},target=/keys/id_ed25519_${USERNAME},readonly",
                "--mount", "type=bind,source=${knownHostsPath},target=/etc/ssh/ssh_known_hosts,readonly",
                # Working directory
                "--workdir", "/home/rstudio/$script:SelectedRepo"
            )
        }

        # Add computational resource limits for remote high-demand containers
        if ($CONTAINER_LOCATION -ne "LOCAL" -and $highComputeDemand) {
            Write-Host "[INFO] Applying high computational resource limits for remote container..." -ForegroundColor Cyan
            $dockerArgs += "--cpus"
            $dockerArgs += "32"  # Limit to 32 CPU cores
            $dockerArgs += "-m"
            $dockerArgs += "384g"  # Limit to 384GB memory
            Write-Host "  CPU Limit: 32 cores" -ForegroundColor Cyan
            Write-Host "  Memory Limit: 384GB" -ForegroundColor Cyan
            Write-Host ""
        }
        
        # Add customParams if specified
        #if ($null -ne $customParams) {
        #    $customParamsArray = $customParams -split '\s+'
        #    $dockerArgs += $customParamsArray
        #}

        # Add final argument (Docker image name)
        $dockerArgs += $DockerImageName

        # Execute docker with the arguments array
        Write-Host ""
        Write-Host "[INFO] Starting RStudio Server container..." -ForegroundColor Cyan
        Write-Host ""
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker $dockerArgs
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:RemoteContextName $dockerArgs
        }
        Write-Host ""
        Write-Host ""
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "[SUCCESS] RStudio Server container started successfully!" -ForegroundColor Green
            Write-Host ""
            
            # Wait a moment for the container to fully start
            Write-Host "[INFO] Waiting for RStudio Server to initialize..." -ForegroundColor Cyan
            Write-Host ""
            Start-Sleep -Seconds 3
            
            # Check if container is still running
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $containerStatus = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
            } else {
                Set-DockerSSHEnvironment
                $containerStatus = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
            }
            if ($containerStatus) {
                Write-Host "[SUCCESS] Container is running: $containerStatus" -ForegroundColor Green
                Write-Host ""
                Write-Host "==============================================="
                Write-Host "  RStudio Server Access Information"
                Write-Host "==============================================="
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    Write-Host "  URL: http://localhost:$(if($portOverride) { $portOverride } else { '8787' })"
                } else {
                    Write-Host "  URL: http://$($script:RemoteHostIp):$(if($portOverride) { $portOverride } else { '8787' })"
                }
                Write-Host "  Username: rstudio"
                Write-Host "  Password: $PASSWORD"
                Write-Host ""
                Write-Host "  Container Name: $CONTAINER_NAME"
                Write-Host "  Execution Location: $CONTAINER_LOCATION"
                Write-Host "==============================================="
                Write-Host ""
                Write-Host "[INFO] Container is running in the background." -ForegroundColor Cyan
                Write-Host "[INFO] Use the 'Stop Container' button to stop it when done." -ForegroundColor Cyan
                
                # Update UI state - container started successfully
                $buttonStart.Enabled = $false
                $buttonStop.Enabled = $true
                Update-InstructionText -Status "RUNNING" -Location $CONTAINER_LOCATION -VolumesInfo "Disabled"
                
            } else {
                Write-Host ""
                Write-Host "[WARNING] Container may have exited. Checking logs..." -ForegroundColor Yellow
                Write-Host ""
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    $containerLogs = & docker logs $CONTAINER_NAME 2>&1
                } else {
                    Set-DockerSSHEnvironment
                    $containerLogs = & docker --context $script:RemoteContextName logs $CONTAINER_NAME 2>&1
                }
                Write-Host "[ERROR] Container logs:" -ForegroundColor Red
                Write-Host $containerLogs
                
                # Container failed to start properly - keep start button enabled
                Write-Host ""
                Write-Host "[ERROR] Container failed to start properly. Please check the logs above." -ForegroundColor Red
            }
        } else {
            Write-Host ""
            Write-Host "[ERROR] Failed to start RStudio Server container" -ForegroundColor Red
            Write-Host ""
            Write-Host "Exit code: $LASTEXITCODE"
            Write-Host ""
            Write-Host "Execution location: $CONTAINER_LOCATION"
            Write-Host ""
        }
    }
})   

$buttonStop.Add_Click({
    Write-Host ""
    Write-Host "[INFO] Container is stopping..." -ForegroundColor Cyan
    Write-Host "  Container: $CONTAINER_NAME"
    Write-Host ""
    
    # Check if container is actually running before attempting to stop
    Write-Host "[INFO] Checking if container '$CONTAINER_NAME' is running..." -ForegroundColor Cyan
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        $containerRunning = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
    } else {
        Set-DockerSSHEnvironment
        $containerRunning = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
    }
    Write-Host ""
    
    if ($containerRunning -and $containerRunning.Trim() -eq $CONTAINER_NAME) {
        Write-Host "[INFO] Container '$CONTAINER_NAME' is running. Stopping..." -ForegroundColor Cyan
        Write-Host ""
        
        try {
            # Stop the container gracefully
            Write-Host "[INFO] Attempting graceful shutdown (SIGTERM)..." -ForegroundColor Cyan
            Write-Host ""
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                & docker stop $CONTAINER_NAME 2>&1 | Out-Null
            } else {
                Set-DockerSSHEnvironment
                & docker --context $script:RemoteContextName stop $CONTAINER_NAME 2>&1 | Out-Null
            }
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[SUCCESS] Container '$CONTAINER_NAME' stopped successfully" -ForegroundColor Green
                Write-Host ""
                
                # Wait a moment to ensure container is fully stopped
                Start-Sleep -Seconds 2
                
                # Verify the container is actually stopped
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    $stillRunning = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
                } else {
                    Set-DockerSSHEnvironment
                    $stillRunning = & docker --context $script:RemoteContextName ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
                }
                if (-not $stillRunning -or $stillRunning.Trim() -ne $CONTAINER_NAME) {
                    Write-Host "[SUCCESS] Container confirmed stopped." -ForegroundColor Green
                    Write-Host ""
                    
                    if ($script:UseVolumes) {
                        Write-Host ""
                        # After the container exits:
                        # Synchronize the output and synthpop volumes back to the local directories using rsync.
                        Write-Host "[INFO] Container exited. Syncing volumes back to local directories using rsync (checksum mode)..." -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Configure paths based on execution location
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            # For local Windows, convert paths for Docker
                            $dockerOutputBackup = Convert-PathToDockerFormat -Path $script:OutputDir
                            $dockerSynthpopBackup = Convert-PathToDockerFormat -Path $script:SynthpopDir
                        } else {
                            # For remote Linux, use paths directly
                            $dockerOutputBackup = $script:OutputDir
                            $dockerSynthpopBackup = $script:SynthpopDir
                        }
                        
                        # Use ${} to delimit variable name before the colon and add permission flags
                        # Added --no-perms and --chmod=ugo=rwX to prevent permission issues on Windows
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeOutput):/volume" -v "${dockerOutputBackup}:/backup" $script:RsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                            & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeSynthpop):/volume" -v "${dockerSynthpopBackup}:/backup" $script:RsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                        } else {
                            Set-DockerSSHEnvironment
                            & docker --context $script:RemoteContextName run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeOutput):/volume" -v "${dockerOutputBackup}:/backup" $script:RsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                            & docker --context $script:RemoteContextName run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeSynthpop):/volume" -v "${dockerSynthpopBackup}:/backup" $script:RsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                        }
                        Write-Host ""

                        # Clean up all the Docker volumes used for the simulation.
                        Write-Host "[INFO] Cleaning up Docker volumes..." -ForegroundColor Cyan
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            & docker volume rm $script:VolumeOutput | Out-Null
                            & docker volume rm $script:VolumeSynthpop | Out-Null
                        } else {
                            Set-DockerSSHEnvironment
                            & docker --context $script:RemoteContextName volume rm $script:VolumeOutput | Out-Null
                            & docker --context $script:RemoteContextName volume rm $script:VolumeSynthpop | Out-Null
                        }
                        Write-Host ""
                    }    

                    # Update UI state - container stopped successfully
                    $buttonStart.Enabled = $true
                    $buttonStop.Enabled = $false
                    Update-InstructionText -Status "STOPPED" -Location $CONTAINER_LOCATION -VolumesInfo $(if($script:UseVolumes) { "Enabled" } else { "Disabled" })
                    
                    Write-Host ""
                    Write-Host "==============================================="
                    Write-Host "  Container Successfully Stopped"
                    Write-Host "==============================================="
                    Write-Host "  Container Name: $CONTAINER_NAME"
                    Write-Host "  Status: STOPPED"
                    Write-Host "  Location: $CONTAINER_LOCATION"
                    Write-Host ""
                    Write-Host "  You can now start a new container or close"
                    Write-Host "  this application."
                    Write-Host "==============================================="
                    Write-Host ""
                    
                    # Check for git changes after container stops
                    if ($script:GitRepoPath) {
                        Invoke-GitChangeDetection -RepoPath $script:GitRepoPath
                    }
                    
                } else {
                    Write-Host ""
                    Write-Host "[WARNING] Container may still be running. Please check Docker Desktop$(if($CONTAINER_LOCATION -ne 'LOCAL') { ' on remote host' })." -ForegroundColor Yellow
                }
                
            } else {
                Write-Host ""
                Write-Host "[ERROR] Failed to stop container '$CONTAINER_NAME'" -ForegroundColor Red
                Write-Host "[INFO] Attempting force stop..." -ForegroundColor Cyan
                Write-Host ""
                
                # Try force stop if graceful stop failed
                & docker kill $CONTAINER_NAME 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host ""
                    Write-Host "[SUCCESS] Container '$CONTAINER_NAME' force stopped" -ForegroundColor Green
                    Write-Host ""
                    
                    # Handle volume cleanup for force stop too
                    if ($script:UseVolumes) {
                        Write-Host ""
                        Write-Host "[INFO] Force stopped - performing volume sync and cleanup..." -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Configure paths based on execution location
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            $dockerOutputBackup = Convert-PathToDockerFormat -Path $script:OutputDir
                            $dockerSynthpopBackup = Convert-PathToDockerFormat -Path $script:SynthpopDir
                        } else {
                            $dockerOutputBackup = $script:OutputDir
                            $dockerSynthpopBackup = $script:SynthpopDir
                        }
                        
                        # Quick sync and cleanup
                        & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeOutput):/volume" -v "${dockerOutputBackup}:/backup" $script:RsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/ 2>$null
                        & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeSynthpop):/volume" -v "${dockerSynthpopBackup}:/backup" $script:RsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/ 2>$null
                        & docker volume rm $script:VolumeOutput $script:VolumeSynthpop -f 2>$null
                        Write-Host ""
                    }
                    
                    # Update UI state
                    $buttonStart.Enabled = $true
                    $buttonStop.Enabled = $false
                    $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SelectedRepo)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($script:UseVolumes) { 'Enabled' } else { 'Disabled' })"
                    
                    # Check for git changes after force stop
                    if ($script:GitRepoPath) {
                        Invoke-GitChangeDetection -RepoPath $script:GitRepoPath
                    }
                } else {
                    Write-Host ""
                    Write-Host "[ERROR] Failed to force stop container '$CONTAINER_NAME'" -ForegroundColor Red
                    Write-Host "[INFO] Please check Docker$(if($CONTAINER_LOCATION -ne 'LOCAL') { ' on remote host' }) and stop the container manually if needed" -ForegroundColor Cyan
                    Write-Host ""
                }
            }
            
        } catch {
            Write-Host ""
            Write-Host "[ERROR] Exception occurred while stopping container: $($_.Exception.Message)" -ForegroundColor Red
            [System.Windows.Forms.MessageBox]::Show("Error stopping container: $($_.Exception.Message)`n`nPlease check Docker Desktop and stop the container manually if needed.", "Container Stop Error", "OK", "Error")
        }
        
    } else {
        Write-Host ""
        Write-Host "[INFO] Container '$CONTAINER_NAME' is not running" -ForegroundColor Cyan
        Write-Host "[INFO] No action needed - updating UI state" -ForegroundColor Cyan
        Write-Host ""
        
        # Container is already stopped - just update UI
        $buttonStart.Enabled = $true
        $buttonStop.Enabled = $false
        $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SelectedRepo)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($script:UseVolumes) { 'Enabled' } else { 'Disabled' })"
        
        Write-Host "[INFO] UI updated to reflect stopped state" -ForegroundColor Cyan
        Write-Host ""
    }
})

<#
Logic to ensure changes inside the container are pushed to github and pulled to the local machine
#>



$buttonOK.Add_Click({
    Write-Host ""
    Write-Host "[INFO] Container management dialog closed" -ForegroundColor Cyan
    $formContainer.Close()
})

# Show the container management dialog
Write-Host ""
Write-Host "Showing container management interface..."
$null = $formContainer.ShowDialog()

Write-Host ""
Write-Host "Container management interface closed."
Write-Host ""



<#
Logic:
    8. If the user closes the script while the container is running we prompt them to stop the container first
#>

#------------------------------------------------#
#   STEP 6: PROMPT AND LOGIC FOR GITHUB PROMPT   #
#------------------------------------------------#

<# 
Logic:
    1. After the user has stopped the container, all file changes are synced back to the local/remote repository folder
    2. We check whether there are any changes in the repository folder (git status)
    3. If yes, we prompt the user whether they want to commit and push the changes to GitHub
    4. If yes, we prompt for a commit message and do the commit and push
    5. If no, we exit the script
    6. If no changes, we exit the script
#>




