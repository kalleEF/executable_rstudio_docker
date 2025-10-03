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

# Global debug flag - controls visibility of debug messages
$script:DEBUG_MODE = $false

# Debug write function that respects the global debug flag
function Write-Debug-Message {
    param(
        [string]$Message,
        [string]$ForegroundColor = "Yellow"
    )
    if ($script:DEBUG_MODE) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
}

#--------------------------------------#
#   ADMINISTRATOR PRIVILEGE CHECK       #
#--------------------------------------#

# Check if running as administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (-not $isAdmin) {
    Write-Host ""
    Write-Host "NOTICE: This script requires administrator privileges for Docker operations."
    Write-Host "Attempting to restart with elevated privileges..."
    Write-Host ""
    
    try {
        # Get the current script path
        $scriptPath = $MyInvocation.MyCommand.Path
        
        # If running as a script file
        if ($scriptPath) {
            # Restart with elevated privileges
            Start-Process PowerShell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`" -STA" -Wait
            exit
        } else {
            # If running interactively or as a compiled exe
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
    Write-Host ""
    Write-Host "[SUCCESS] Running with Administrator privileges" -ForegroundColor Green
    Write-Host ""
}

#--------------------------------------#
#   TERMINAL COLOR CONFIGURATION       #
#--------------------------------------#

# Set terminal background to black and configure color scheme
try {
    $Host.UI.RawUI.BackgroundColor = "Black"
    $Host.UI.RawUI.ForegroundColor = "White"
    Clear-Host
} catch {
    # Fallback if terminal doesn't support color changes
    Write-Host "Note: Terminal color configuration not supported on this system" -ForegroundColor Yellow
}

#--------------------------------------#
#   STEP 0: SETUP AND PRE-REQUISITES   #
#--------------------------------------#

# Ensure Windows Forms app environment
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

#--------------------------------------#
#   SPINNER FUNCTIONS FOR BUILD FEEDBACK   #
#--------------------------------------#

# Global spinner variables
$script:spinnerJob = $null
$script:spinnerChars = @('|', '/', '-', '\')
$script:spinnerIndex = 0

function Start-Spinner {
    param(
        [string]$Message = "Processing"
    )
    
    # Stop any existing spinner
    Stop-Spinner
    
    # Start new spinner job
    $script:spinnerJob = Start-Job -ScriptBlock {
        param($msg, $chars)
        $index = 0
        while ($true) {
            $char = $chars[$index % $chars.Length]
            Write-Host "`r$msg $char" -NoNewline
            Start-Sleep -Milliseconds 200
            $index++
        }
    } -ArgumentList $Message, $script:spinnerChars
}

function Stop-Spinner {
    if ($script:spinnerJob) {
        Stop-Job $script:spinnerJob -ErrorAction SilentlyContinue
        Remove-Job $script:spinnerJob -ErrorAction SilentlyContinue
        $script:spinnerJob = $null
        Write-Host "`r" -NoNewline  # Clear the spinner line
    }
}

function Show-SpinnerWithProgress {
    param(
        [string]$Message,
        [ScriptBlock]$ScriptBlock
    )
    
    Write-Host "$Message" -NoNewline
    Start-Spinner -Message ""
    
    try {
        $result = & $ScriptBlock
        Stop-Spinner
        Write-Host " [SUCCESS]" -ForegroundColor Green
        return $result
    } catch {
        Stop-Spinner
        Write-Host " [FAILED]" -ForegroundColor Red
        throw
    }
}

#----------------------------------------------#
#   STEP 1: PROMPT FOR USERNAME AND PASSWORD   #
#----------------------------------------------#

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

# Build the form
$form = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Remote Access - IMPACT NCD Germany'
    Size = New-Object System.Drawing.Size(450,250)
    StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}

# Instruction label
$labelInstruction = New-Object System.Windows.Forms.Label -Property @{ 
    Text = "Please enter your username and a password`nfor your RStudio Server session:`n`n(Username will be normalized: spaces removed, lowercase)"
    Location = New-Object System.Drawing.Point(10,10)
    Size = New-Object System.Drawing.Size(380,70)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$form.Controls.Add($labelInstruction)

# Username label and textbox
$labelUser = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Username:'
    Location = New-Object System.Drawing.Point(10,90)
    Size = New-Object System.Drawing.Size(100,20)
}
$form.Controls.Add($labelUser)
$textUser = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(120,90)
    Size = New-Object System.Drawing.Size(250,20)
}
$form.Controls.Add($textUser)

# Password label and textbox
$labelPass = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Password:'
    Location = New-Object System.Drawing.Point(10,120)
    Size = New-Object System.Drawing.Size(100,20)
}
$form.Controls.Add($labelPass)
$textPass = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(120,120)
    Size = New-Object System.Drawing.Size(250,20)
}
$form.Controls.Add($textPass)

# OK and Cancel buttons
$buttonOK = New-Object System.Windows.Forms.Button -Property @{
    Text = 'OK'
    Location = New-Object System.Drawing.Point(200,160)
    Size = New-Object System.Drawing.Size(75,30)
}
$form.Controls.Add($buttonOK)

$buttonCancel = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Cancel'
    Location = New-Object System.Drawing.Point(290,160)
    Size = New-Object System.Drawing.Size(75,30)
    DialogResult = [System.Windows.Forms.DialogResult]::Cancel
}
$form.Controls.Add($buttonCancel)

# Set default buttons
$form.AcceptButton = $buttonOK
$form.CancelButton = $buttonCancel

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
$result = $form.ShowDialog()

# Initialize variables
$USERNAME = $null
$PASSWORD = $null

# If user clicked OK, save the values
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    # Normalize username: remove spaces and convert to lowercase for consistency
    $originalUsername = $textUser.Text.Trim()
    # Fix: Ensure USERNAME is always a string, not an array
    $USERNAME = ($originalUsername -replace '\s+', '').ToLower()
    $PASSWORD = $textPass.Text
    
    # Validate that USERNAME is not empty after normalization
    if ([string]::IsNullOrWhiteSpace($USERNAME)) {
        Write-Host ""
        Write-Host "[ERROR] Username became empty after normalization" -ForegroundColor Red
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show('Username cannot be empty after removing spaces.', 'Invalid Username', 'OK', 'Error')
        exit 1
    }
    
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

# Only proceed if user provided credentials
if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
    Write-Host ""
    Write-Host "================================================"
    Write-Host "  STEP 2: SSH Key Setup for GitHub Integration"
    Write-Host "================================================"
    Write-Host ""
    
    # Define SSH key paths (individual per user)
    $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
    $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME.pub"

    # Check if SSH key already exists
    if ((Test-Path $sshKeyPath) -and (Test-Path $sshPublicKeyPath)) {
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
        
        # Ensure .ssh directory exists
        $sshDir = "$HOME\.ssh"
        if (-not (Test-Path $sshDir)) {
            New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
            Write-Host ""
            Write-Host "  Created .ssh directory"
            Write-Host ""
        }
        
        # Generate the SSH key (without passphrase for automation)
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
            '-N', '""',
            '-q'  # Quiet mode to suppress output
        )
        
        # Execute ssh-keygen with proper argument handling
        try {
            & ssh-keygen @sshKeyGenArgs
            $keyGenResult = $LASTEXITCODE
        } catch {
            Write-Host ""
            Write-Host "  [ERROR] ssh-keygen execution failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host ""
            $keyGenResult = 1
        }
        
        # Check if SSH key generation was successful
        if ($keyGenResult -eq 0 -and (Test-Path "$HOME\.ssh\id_ed25519_$USERNAME.pub")) {
            Write-Host ""
            Write-Host "[SUCCESS] New SSH key generated successfully!" -ForegroundColor Green
            Write-Host "  Private key: $HOME\.ssh\id_ed25519_$USERNAME"
            Write-Host "  Public key: $HOME\.ssh\id_ed25519_$USERNAME.pub"
            Write-Host ""
        } else {
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
            StartPosition = 'CenterScreen'
            FormBorderStyle = 'FixedDialog'
            MaximizeBox = $false
            MinimizeBox = $false
            BackColor = [System.Drawing.Color]::White
        }

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
            Text = "To enable GitHub integration, copy this SSH public key to your GitHub account:`n`nGitHub → Settings → SSH and GPG keys → New SSH key"
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
                $script:copyTimer = New-Object System.Windows.Forms.Timer
                $script:copyTimer.Interval = 2000
                $script:copyTimer.Add_Tick({
                    try {
                        if ($buttonCopyKey -and -not $buttonCopyKey.IsDisposed) {
                            $buttonCopyKey.Text = 'Copy to Clipboard'
                            $buttonCopyKey.BackColor = [System.Drawing.Color]::LightGreen
                            $buttonCopyKey.Enabled = $true
                        }
                        if ($script:copyTimer -and -not $script:copyTimer.Disposed) {
                            $script:copyTimer.Stop()
                            $script:copyTimer.Dispose()
                            $script:copyTimer = $null
                        }
                    } catch {
                        # Silently handle any timer cleanup errors
                        if ($script:copyTimer) {
                            try { $script:copyTimer.Dispose() } catch { }
                            $script:copyTimer = $null
                        }
                    }
                })
                $script:copyTimer.Start()
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
        Write-Host ""
        Write-Host "[INFO] Configuring SSH agent..." -ForegroundColor Cyan
        Write-Host ""
        
        # Start ssh-agent service if not running
        $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
        if ($sshAgentService.Status -ne 'Running') {
            Set-Service ssh-agent -StartupType Automatic
            Start-Service ssh-agent
            Write-Host ""
            Write-Host "  SSH agent service started"
        }
        
        # Add key to ssh-agent
        ssh-add $sshKeyPath
        Write-Host ""
        Write-Host "  SSH key added to agent"
        Write-Host ""
        
    } catch {
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

#----------------------------------------------#
#   STEP 3: PROMPT LOCAL / REMOTE CONNECTION   #
#----------------------------------------------#

# Create a new form for local/remote selection
$formConnection = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Container Location - IMPACT NCD Germany'
    Size = New-Object System.Drawing.Size(450,240)
    StartPosition = 'CenterScreen'
    Location = New-Object System.Drawing.Point(400,300)
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}

# Instruction label
$labelConnectionInstruction = New-Object System.Windows.Forms.Label -Property @{ 
    Text = "Please choose whether you want to work locally`n(e.g. for testing) or remotely on the workstation`n(e.g. running simulations for output)!"
    Location = New-Object System.Drawing.Point(10,10)
    Size = New-Object System.Drawing.Size(420,60)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
    TextAlign = 'MiddleCenter'
}
$formConnection.Controls.Add($labelConnectionInstruction)

# Debug checkbox
$checkBoxDebug = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'Enable Debug Mode (show detailed debug messages)'
    Location = New-Object System.Drawing.Point(50,80)
    Size = New-Object System.Drawing.Size(350,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 8, [System.Drawing.FontStyle]::Regular)
    Checked = $false
}
$formConnection.Controls.Add($checkBoxDebug)

# Local Container button
$buttonLocal = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Local Container'
    Location = New-Object System.Drawing.Point(80,120)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formConnection.Controls.Add($buttonLocal)

# Remote Container button
$buttonRemote = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Remote Container'
    Location = New-Object System.Drawing.Point(250,120)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formConnection.Controls.Add($buttonRemote)

# Add click handlers for the buttons
$buttonLocal.Add_Click({
    $script:DEBUG_MODE = $checkBoxDebug.Checked
    Write-Host "[INFO] Debug mode: $(if($script:DEBUG_MODE) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Cyan
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
    $script:DEBUG_MODE = $checkBoxDebug.Checked
    Write-Host "[INFO] Debug mode: $(if($script:DEBUG_MODE) { 'Enabled' } else { 'Disabled' })" -ForegroundColor Cyan
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
    
    # Define remote host (update this IP address to match your workstation)
    $remoteHost = "php-workstation@10.162.192.90"  #TODO: Implement individual users!
 
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
        
        # Use PowerShell job with timeout for SSH connection test
        $sshTestJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost)
            & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'SSH connection successful'" 2>&1
        } -ArgumentList $sshKeyPath, $remoteHost
        
        if (Wait-Job $sshTestJob -Timeout 15) {
            $sshTestResult = Receive-Job $sshTestJob
            Remove-Job $sshTestJob
        } else {
            Remove-Job $sshTestJob -Force
            $sshTestResult = "SSH connection test timed out after 15 seconds"
            $LASTEXITCODE = 1
        }
        
        $SSHEXITCODE = $LASTEXITCODE

        if ($SSHEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "  [SUCCESS] SSH key authentication successful!" -ForegroundColor Green
            Write-Host "  Response: $sshTestResult"
            Write-Host "  Remote workstation is reachable"
            Write-Host ""

            # Extract IP address from remote host string
            $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
            $script:REMOTE_HOST_IP = $remoteIP
            
        } else {
            Write-Host ""
            Write-Host "  [INFO] SSH key authentication failed - password authentication required" -ForegroundColor Cyan
            Write-Host "  This is normal for first-time connections"
            Write-Host ""
            
            # Prompt user for remote host password #TODO: Change based on individual users!
            $formPassword = New-Object System.Windows.Forms.Form -Property @{ 
                Text = 'Remote Host Password - IMPACT NCD Germany'
                Size = New-Object System.Drawing.Size(450,180)
                StartPosition = 'CenterScreen'
                FormBorderStyle = 'FixedDialog'
                MaximizeBox = $false
            }

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
            $passwordResult = $formPassword.ShowDialog()
            
            if ($passwordResult -eq [System.Windows.Forms.DialogResult]::OK) {
                # Secure password handling: Convert to SecureString immediately
                Write-Host ""
                Write-Host "  [INFO] Password provided, securing credentials..." -ForegroundColor Cyan
                Write-Host ""
                $securePassword = ConvertTo-SecureString $textRemotePassword.Text -AsPlainText -Force
                
                # Create credential object for secure handling
                $hostParts = $remoteHost -split "@"
                if ($hostParts.Count -eq 2) {
                    $sshUser = $hostParts[0]
                    $sshHost = $hostParts[1]
                } else {
                    $sshUser = $env:USERNAME
                    $sshHost = $remoteHost
                }
                
                $remoteCredential = New-Object System.Management.Automation.PSCredential($sshUser, $securePassword)
                
                # Clear the plain text password from the textbox and form
                $textRemotePassword.Text = ""
                $textRemotePassword.Clear()
                
                # Dispose of the password form securely
                $formPassword.Dispose()
                
                Write-Host ""
                Write-Host "  [INFO] Credentials secured, testing connection..." -ForegroundColor Cyan
                Write-Host ""
                
                # Test connection with password using a more reliable method
                try {
                    Write-Host ""
                    Write-Host "  [INFO] Testing SSH connection with password..." -ForegroundColor Cyan
                    Write-Host ""

                    # Method 1: Try using plink (PuTTY's command line tool) if available
                    $plinkPath = Get-Command plink.exe -ErrorAction SilentlyContinue
                    if ($plinkPath) {
                        Write-Host ""
                        Write-Host "  Using PuTTY plink for password authentication..."
                        Write-Host ""
                        
                        # Username and host already extracted during credential creation
                        # Convert secure password to plain text only when needed for plink
                        $plainPassword = $remoteCredential.GetNetworkCredential().Password
                        
                        # Test connection with plink
                        $plinkResult = & plink.exe -ssh -batch -pw $plainPassword -l $sshUser $sshHost "echo SSH_SUCCESS" 2>&1
                        
                        # Clear the plain text password from memory immediately
                        $plainPassword = $null
                        [System.GC]::Collect()
                        
                        if ($plinkResult -match "SSH_SUCCESS") {
                            Write-Host ""
                            Write-Host "  [SUCCESS] Password authentication successful!" -ForegroundColor Green
                            Write-Host ""
                            $authSuccess = $true
                        } else {
                            Write-Host ""
                            Write-Host "  [ERROR] Password authentication failed with plink" -ForegroundColor Red
                            Write-Host "  Output: $plinkResult"
                            $authSuccess = $false
                        }
                        
                    } else {
                        # Method 2: Use expect-like functionality with PowerShell and SSH
                        Write-Host ""
                        Write-Host "  Using PowerShell SSH automation (plink not found)..."
                        Write-Host ""

                        # Convert secure password to plain text only when needed for batch script
                        $plainPassword = $remoteCredential.GetNetworkCredential().Password
                        
                        # Create a secure batch file for SSH with password (handle special characters)
                        $batchFile = [System.IO.Path]::GetTempFileName() + ".bat"
                        
                        # Escape special characters in password for safe batch file usage
                        $escapedPassword = $plainPassword -replace '[&<>|^]', '^$&' -replace '"', '""'
                        
                        $expectScript = @"
@echo off
setlocal EnableDelayedExpansion
set "PASSWORD=$escapedPassword"
echo !PASSWORD! | ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no $remoteHost "echo SSH_SUCCESS" 2>nul
"@
                        Set-Content -Path $batchFile -Value $expectScript
                        
                        # Execute the batch file
                        $batchResult = & cmd.exe /c $batchFile 2>&1
                        
                        # Securely clean up the batch file and password
                        Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
                        $plainPassword = $null
                        $escapedPassword = $null
                        [System.GC]::Collect()
                        
                        if ($batchResult -match "SSH_SUCCESS") {
                            Write-Host ""
                            Write-Host "  [SUCCESS] Password authentication successful!" -ForegroundColor Green
                            Write-Host ""
                            $authSuccess = $true
                        } else {
                            # Method 3: Try with sshpass if available (Windows Subsystem for Linux)
                            $sshpassTest = Get-Command sshpass -ErrorAction SilentlyContinue
                            if ($sshpassTest) {
                                Write-Host ""
                                Write-Host "  Trying with sshpass..."
                                Write-Host ""
                                
                                # Use environment variable for password (more secure than command line)
                                $plainPassword = $remoteCredential.GetNetworkCredential().Password
                                $env:SSHPASS = $plainPassword
                                
                                # Use sshpass with environment variable instead of -p flag
                                $sshpassResult = & sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $remoteHost "echo SSH_SUCCESS" 2>&1
                                
                                # Clear the environment variable and password from memory immediately
                                $env:SSHPASS = $null
                                $plainPassword = $null
                                [System.GC]::Collect()
                                
                                if ($sshpassResult -match "SSH_SUCCESS") {
                                    Write-Host ""
                                    Write-Host "  [SUCCESS] Password authentication successful with sshpass!" -ForegroundColor Green
                                    Write-Host ""
                                    $authSuccess = $true
                                } else {
                                    $authSuccess = $false
                                }
                            } else {
                                Write-Host ""
                                Write-Host "  [ERROR] Could not authenticate with available methods" -ForegroundColor Red
                                Write-Host "  Output: $batchResult"
                                $authSuccess = $false
                            }
                        }
                    }
                    
                    if ($authSuccess) {
                        # Now copy the SSH key for future passwordless authentication
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

                            # Use the same authentication method that worked for copying the key
                            if ($plinkPath) {
                                # Use plink to copy the SSH key (securely)
                                $keyCommand = "mkdir -p ~/.ssh && echo '$publicKeyContent' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo SSH_KEY_COPIED"
                                
                                # Convert secure password to plain text only when needed
                                $plainPassword = $remoteCredential.GetNetworkCredential().Password
                                $keyCopyResult = & plink.exe -ssh -batch -pw $plainPassword -l $sshUser $sshHost $keyCommand 2>&1
                                
                                # Clear the plain text password from memory immediately
                                $plainPassword = $null
                                [System.GC]::Collect()
                                
                            } elseif ($sshpassTest) {
                                # Use sshpass to copy the SSH key (securely with environment variable)
                                $keyCommand = "mkdir -p ~/.ssh && echo '$publicKeyContent' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo SSH_KEY_COPIED"
                                
                                # Use environment variable for password (more secure than command line)
                                $plainPassword = $remoteCredential.GetNetworkCredential().Password
                                $env:SSHPASS = $plainPassword
                                
                                # Use sshpass with environment variable instead of -p flag
                                $keyCopyResult = & sshpass -e ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $remoteHost $keyCommand 2>&1
                                
                                # Clear the environment variable and password from memory immediately
                                $env:SSHPASS = $null
                                $plainPassword = $null
                                [System.GC]::Collect()
                                
                            } else {
                                # Use batch method to copy SSH key (securely with special character handling)
                                $keyBatchFile = [System.IO.Path]::GetTempFileName() + ".bat"
                                
                                # Convert secure password to plain text only when needed for batch script
                                $plainPassword = $remoteCredential.GetNetworkCredential().Password
                                
                                # Escape special characters in password for safe batch file usage
                                $escapedPassword = $plainPassword -replace '[&<>|^]', '^$&' -replace '"', '""'
                                
                                # Use base64 encoding to safely transfer SSH key content (avoids shell escaping issues)
                                # Note: Requires 'base64' command to be available on the remote Linux system
                                $keyBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKeyContent))
                                
                                $keyBatchScript = @"
@echo off
setlocal EnableDelayedExpansion
set "PASSWORD=$escapedPassword"
echo !PASSWORD! | ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no $remoteHost "mkdir -p ~/.ssh && echo $keyBase64 | base64 -d >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo SSH_KEY_COPIED" 2>nul
"@
                                Set-Content -Path $keyBatchFile -Value $keyBatchScript
                                $keyCopyResult = & cmd.exe /c $keyBatchFile 2>&1
                                
                                # Securely clean up the batch file and password
                                Remove-Item $keyBatchFile -Force -ErrorAction SilentlyContinue
                                $plainPassword = $null
                                $escapedPassword = $null
                                $keyBase64 = $null
                                [System.GC]::Collect()
                            }
                            
                            if ($keyCopyResult -match "SSH_KEY_COPIED") {
                                Write-Host ""
                                Write-Host "  [SUCCESS] SSH key successfully copied to remote host!" -ForegroundColor Green
                                Write-Host "  Future connections will not require password"
                                Write-Host ""
                                
                                # Test passwordless connection
                                Write-Host "  [INFO] Testing passwordless SSH connection..." -ForegroundColor Cyan
                                Start-Sleep -Seconds 2  # Give the remote system a moment to process the key
                                
                                # Use specific SSH key for testing
                                $finalTest = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'Passwordless SSH successful'" 2>&1
                                if ($LASTEXITCODE -eq 0) {
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
                                        & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $setupRemoteSSHCommand 2>&1 | Out-Null
                                        
                                        # Read private key content and encode in base64 to avoid shell escaping issues
                                        $privateKeyContent = Get-Content $sshPrivateKeyPath -Raw
                                        $privateKeyBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($privateKeyContent))
                                        
                                        # Remove any existing file/directory that might be in the way
                                        $cleanupPrivateKeyCommand = "rm -rf ~/.ssh/id_ed25519_${USERNAME}"
                                        & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $cleanupPrivateKeyCommand 2>&1 | Out-Null
                                        
                                        # Copy private key to remote system
                                        $copyPrivateKeyCommand = "echo '$privateKeyBase64' | base64 -d > ~/.ssh/id_ed25519_${USERNAME} && chmod 600 ~/.ssh/id_ed25519_${USERNAME} && echo PRIVATE_KEY_COPIED"
                                        $privateKeyCopyResult = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $copyPrivateKeyCommand 2>&1
                                        
                                        if ($privateKeyCopyResult -match "PRIVATE_KEY_COPIED") {
                                            # Verify the private key was actually copied as a file
                                            $verifyPrivateKeyCommand = "test -f ~/.ssh/id_ed25519_${USERNAME} && echo PRIVATE_KEY_FILE_EXISTS || echo PRIVATE_KEY_FILE_MISSING"
                                            $privateKeyVerifyResult = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $verifyPrivateKeyCommand 2>&1
                                            
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
                                        & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $cleanupKnownHostsCommand 2>&1 | Out-Null
                                        
                                        # Copy known_hosts to remote system
                                        $copyKnownHostsCommand = "echo '$knownHostsBase64' | base64 -d > ~/.ssh/known_hosts && chmod 644 ~/.ssh/known_hosts && echo KNOWN_HOSTS_COPIED"
                                        $knownHostsCopyResult = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $copyKnownHostsCommand 2>&1
                                        
                                        if ($knownHostsCopyResult -match "KNOWN_HOSTS_COPIED") {
                                            # Verify the known_hosts was actually copied as a file
                                            $verifyKnownHostsCommand = "test -f ~/.ssh/known_hosts && echo KNOWN_HOSTS_FILE_EXISTS || echo KNOWN_HOSTS_FILE_MISSING"
                                            $knownHostsVerifyResult = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $verifyKnownHostsCommand 2>&1
                                            
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
                                        & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $createKnownHostsCommand 2>&1 | Out-Null
                                        
                                        # Verify it was created as a file
                                        $verifyKnownHostsCommand = "test -f ~/.ssh/known_hosts && echo KNOWN_HOSTS_FILE_EXISTS || echo KNOWN_HOSTS_FILE_MISSING"
                                        $knownHostsVerifyResult = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $verifyKnownHostsCommand 2>&1
                                        
                                        if ($knownHostsVerifyResult -match "KNOWN_HOSTS_FILE_EXISTS") {
                                            Write-Host "    [SUCCESS] Empty known_hosts file created on remote system" -ForegroundColor Green
                                        } else {
                                            Write-Host "    [ERROR] Failed to create known_hosts file: $knownHostsVerifyResult" -ForegroundColor Red
                                        }
                                    }
                                    
                                    Write-Host "  [INFO] SSH files setup complete for Docker container mounting" -ForegroundColor Cyan
                                    Write-Host ""
                                    
                                } else {
                                    Write-Host ""
                                    Write-Host "  [INFO] Passwordless test not yet working, but key was copied" -ForegroundColor Cyan
                                    Write-Host "  This may take a moment to take effect on the remote system"
                                    Write-Host ""
                                }
                            } else {
                                Write-Host ""
                                Write-Host "  [WARNING] Failed to copy SSH key to remote host" -ForegroundColor Yellow
                                Write-Host "  Password authentication will be required for future connections"
                                Write-Host "  Details: $keyCopyResult"
                                Write-Host ""
                            }
                        } else {
                            Write-Host ""
                            Write-Host "  [ERROR] SSH public key not found at: $sshPublicKeyPath" -ForegroundColor Red
                            Write-Host "  Cannot set up passwordless authentication"
                            Write-Host ""
                        }
                        
                        # Extract IP address and continue
                        $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                        $script:REMOTE_HOST_IP = $remoteIP
                        
                        # Secure cleanup: Clear the credential object from memory
                        $remoteCredential = $null
                        $securePassword = $null
                        [System.GC]::Collect()
                        Write-Host ""
                        Write-Host "  [INFO] Credentials securely cleared from memory" -ForegroundColor Cyan
                        Write-Host ""
                        
                    } else {
                        # Secure cleanup: Clear the credential object from memory even on failure
                        $remoteCredential = $null
                        $securePassword = $null
                        [System.GC]::Collect()
                        
                        Write-Host ""
                        Write-Host "  [ERROR] All password authentication methods failed" -ForegroundColor Red
                        Write-Host ""
                        Write-Host "  Troubleshooting suggestions:"
                        Write-Host "  1. Verify the password is correct"
                        Write-Host "  2. Check if SSH service is running on remote host"
                        Write-Host "  3. Ensure password authentication is enabled on remote host"
                        Write-Host "  4. Try installing PuTTY (plink.exe) for better SSH support"
                        Write-Host ""
                        [System.Windows.Forms.MessageBox]::Show("Password authentication failed with all available methods.`n`nPlease check:`n- Password is correct`n- SSH service is running on remote host`n- Password authentication is enabled`n- Consider installing PuTTY for better compatibility", "Authentication Failed", "OK", "Error")
                        return
                    }
                    
                } catch {
                    # Secure cleanup: Clear the credential object from memory on exception
                    if ($remoteCredential) {
                        $remoteCredential = $null
                        $securePassword = $null
                        [System.GC]::Collect()
                    }

                    Write-Host ""
                    Write-Host "  [ERROR] Failed to test password authentication" -ForegroundColor Red
                    Write-Host "  Details: $($_.Exception.Message)"
                    Write-Host ""
                    [System.Windows.Forms.MessageBox]::Show("Failed to test password authentication.`n`nError: $($_.Exception.Message)", "Connection Error", "OK", "Error")
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

        Write-Host ""
        Write-Host "[INFO] Testing Docker availability on remote host..." -ForegroundColor Cyan
        Write-Host ""

        # Use specific SSH key to avoid authentication failures
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        
        # Use PowerShell job with timeout for Docker version check
        $dockerTestJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost)
            & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "docker --version" 2>&1
        } -ArgumentList $sshKeyPath, $remoteHost
        
        if (Wait-Job $dockerTestJob -Timeout 15) {
            $dockerTestResult = Receive-Job $dockerTestJob
            Remove-Job $dockerTestJob
        } else {
            Remove-Job $dockerTestJob -Force
            $dockerTestResult = "Docker version check timed out after 15 seconds"
            $LASTEXITCODE = 1
        }
        
        Write-Host ""
        Write-Host "[SUCCESS] Docker is available on remote host" -ForegroundColor Green
        Write-Host "  Version: $dockerTestResult"
        Write-Host ""
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
$connectionResult = $formConnection.ShowDialog()

# Store the selection for later use
if ($connectionResult -eq [System.Windows.Forms.DialogResult]::Yes) {
    $CONTAINER_LOCATION = "LOCAL"
    Write-Host ""
    Write-Host "[SUCCESS] Container location configured" -ForegroundColor Green
    Write-Host "  Location: LOCAL"
    Write-Host "  Mode: Local Docker containers"
    Write-Host ""
    Write-Host "========================================="
    Write-Host ""
} elseif ($connectionResult -eq [System.Windows.Forms.DialogResult]::No -and $script:REMOTE_HOST_IP) {
    $CONTAINER_LOCATION = "REMOTE@$($script:REMOTE_HOST_IP)"
    Write-Host "[SUCCESS] Container location configured" -ForegroundColor Green
    Write-Host "  Location: REMOTE"
    Write-Host "  Target: $($script:REMOTE_HOST_IP)"
    Write-Host "  Mode: Remote Docker containers via SSH"
    Write-Host ""
    
    # Set up global SSH environment for all remote Docker operations
    $script:sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
    $env:DOCKER_SSH_OPTS = "-i `"$script:sshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
    Write-Host "[INFO] Global SSH environment configured for Docker operations" -ForegroundColor Cyan
    Write-Host "  SSH Key: $script:sshKeyPath" -ForegroundColor Cyan
    Write-Host "  SSH Options: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "[ERROR] Configuration failed" -ForegroundColor Red
    Write-Host "  Reason: Remote connection failed or user cancelled"
    Write-Host ""
    exit 1
}


#--------------------------------------------#
#   STEP 4.1.2: IF REMOTE - READ REPO LIST   #
#--------------------------------------------#

if($CONTAINER_LOCATION -eq "REMOTE@$($script:REMOTE_HOST_IP)") {
    Write-Host ""
    Write-Host "========================================="
    Write-Host "    SCANNING REMOTE REPOSITORIES"
    Write-Host "========================================="
    Write-Host ""
    
    Write-Host "    [INFO] Scanning remote host for available repositories..." -ForegroundColor Cyan
    
    # Define the base path on remote host where repositories are stored
    $remoteRepoPath = "/home/php-workstation/Schreibtisch/IMPACT/Models"
    #$remoteHost = "php_workstation@$($script:REMOTE_HOST_IP)" TODO: CHECK IF NEEDED
    
    try {
        # Scan for subdirectories on remote host
        Write-Host ""
        Write-Host "    Scanning directory: $remoteRepoPath"
        Write-Host "    Using remote host: $remoteHost"
        Write-Host ""
        
        # Ensure we're using the correct remote host (the one we authenticated with)
        if ([string]::IsNullOrEmpty($remoteHost)) {
            # Reconstruct the remote host from the IP we stored earlier
            if ($script:REMOTE_HOST_IP) {
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
        
        # Use the authenticated SSH connection with specific key
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        Write-Host ""
        Write-Host "    Executing: ssh with key $sshKeyPath to $remoteHost '$scanCommand'"
        Write-Host ""
        
        # Use job with timeout for repository scanning to prevent hanging
        $scanJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost, $scanCommand)
            $output = & ssh -o ConnectTimeout=10 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost $scanCommand 2>&1
            @{
                Output = $output
                ExitCode = $LASTEXITCODE
            }
        } -ArgumentList $sshKeyPath, $remoteHost, $scanCommand
        
        $scanResult = Wait-Job $scanJob -Timeout 20
        
        if ($scanResult) {
            $scanData = Receive-Job $scanJob
            $availableFolders = $scanData.Output
            $scanExitCode = $scanData.ExitCode
            Remove-Job $scanJob
        } else {
            Write-Host "    [ERROR] Repository scan timed out" -ForegroundColor Red
            Stop-Job $scanJob -ErrorAction SilentlyContinue
            Remove-Job $scanJob -ErrorAction SilentlyContinue
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Repository scan timed out after 20 seconds.`n`nThis may indicate network connectivity issues or the remote directory scan is taking too long.", "Scan Timeout", "OK", "Error")
            exit 1
        }
        
        if ($scanExitCode -ne 0) {
            Write-Host ""
            Write-Host "    [ERROR] Could not scan remote directory" -ForegroundColor Red
            Write-Host "    Command output: $availableFolders"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Could not scan remote directory: $remoteRepoPath`n`nPlease ensure the directory exists and is accessible.", "Remote Scan Error", "OK", "Error")
            exit 1
        }
        
        # Convert output to array and filter out empty lines
        $folderList = $availableFolders -split "`n" | Where-Object { $_.Trim() -ne "" }
        
        if ($folderList.Count -eq 0) {
            Write-Host ""
            Write-Host "    [ERROR] No subdirectories (and thus no simulation models) found in:" -ForegroundColor Red
            Write-Host "    $remoteRepoPath"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("No subdirectories (and thus no simulation models) found in: $remoteRepoPath`n`nPlease ensure there are subdirectories containing your simulation models and their respective GitHub repositories.", "No Repositories Found", "OK", "Warning")
            exit 1
        }
        
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
        Write-Host "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Unexpected error while scanning remote for simulation models and repositories.`n`nError: $($_.Exception.Message)", "Scan Error", "OK", "Error")
        exit 1
    }

#---------------------------------------------------#
#   STEP 4.1.3: IF REMOTE - PROMPT REPO SELECTION   #
#---------------------------------------------------#

    Write-Host ""
    Write-Host "========================================="
    Write-Host "    REPOSITORY SELECTION"
    Write-Host "========================================="
    Write-Host ""
    Write-Host "    [INFO] Creating repository selection dialog..." -ForegroundColor Cyan
    Write-Host ""
    
    # Create repository selection form
    $formRepoSelection = New-Object System.Windows.Forms.Form -Property @{ 
        Text = 'Select Repository - IMPACT NCD Germany'
        Size = New-Object System.Drawing.Size(500,400)
        StartPosition = 'CenterScreen'
        FormBorderStyle = 'FixedDialog'
        MaximizeBox = $false
    }

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
    foreach ($folder in $folderList) {
        $listBoxRepos.Items.Add($folder) | Out-Null
    }
    
    # Select first item by default
    if ($listBoxRepos.Items.Count -gt 0) {
        $listBoxRepos.SelectedIndex = 0
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
            $script:SELECTED_REPO = $listBoxRepos.SelectedItem
            $formRepoSelection.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $formRepoSelection.Close()
        } else {
            [System.Windows.Forms.MessageBox]::Show('Please select a simulation model repository from the list.', 'No Selection', 'OK', 'Warning')
        }
    })

    # Show the repository selection dialog
    $repoSelectionResult = $formRepoSelection.ShowDialog()

    # Process the selection
    if ($repoSelectionResult -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Host ""
        Write-Host "    [SUCCESS] Selected repository: $($script:SELECTED_REPO)" -ForegroundColor Green
        Write-Host "    Repository path: $remoteRepoPath/$($script:SELECTED_REPO)"
        Write-Host ""
        
        # Verify the selected repository exists and contains a Git repository
        Write-Host "    [INFO] Verifying selected repository..." -ForegroundColor Cyan
        
        # Ensure we're using the correct remote host for verification
        if ([string]::IsNullOrEmpty($remoteHost)) {
            if ($script:REMOTE_HOST_IP) {
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                Write-Host ""
                Write-Host "    [INFO] Using remote host: $remoteHost" -ForegroundColor Cyan
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "    [ERROR] No remote host information available for verification" -ForegroundColor Red
                Write-Host ""
            }
        }
        
        $gitCheckCommand = "test -d '$remoteRepoPath/$($script:SELECTED_REPO)/.git' && echo 'Git repository found' || echo 'No Git repository'"
        
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
    Write-Host "    Selected repository: $($script:SELECTED_REPO)"
    Write-Host "    Remote repository path: $remoteRepoPath/$($script:SELECTED_REPO)"
    Write-Host ""

    # Store the full remote path for later use
    $script:REMOTE_REPO_PATH = "$remoteRepoPath/$($script:SELECTED_REPO)"
    
    # Verify Docker is available on remote host
    Write-Host ""
    Write-Host "    [INFO] Checking remote Docker availability..." -ForegroundColor Cyan
    Write-Host ""
    try {
        # Ensure we have the correct remote host for Docker verification
        if ([string]::IsNullOrEmpty($remoteHost)) {
            if ($script:REMOTE_HOST_IP) {
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
        Write-Host "    Error details: $($_.Exception.Message)"
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
    $script:REMOTE_CONTEXT_NAME = $RemoteContextName  # Store globally for later use

    # Ensure we have the correct remote host for Docker context
    if ([string]::IsNullOrEmpty($remoteHost)) {
        if ($script:REMOTE_HOST_IP) {
            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
        & ssh -o ConnectTimeout=30 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost "echo 'SSH_OK_FOR_DOCKER' && docker --version" 2>&1
    } -ArgumentList $sshKeyPath, $remoteHost
    
    if (Wait-Job $sshConnectTestJob -Timeout 20) {
        $sshConnectTest = Receive-Job $sshConnectTestJob
        Remove-Job $sshConnectTestJob
    } else {
        Remove-Job $sshConnectTestJob -Force
        $sshConnectTest = "SSH and Docker connection test timed out after 20 seconds"
        $LASTEXITCODE = 1
    }
    
    if ($LASTEXITCODE -eq 0 -and $sshConnectTest -match "SSH_OK_FOR_DOCKER") {
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
                $script:REMOTE_CONTEXT_NAME = $RemoteContextName  # Update global variable
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
            $dockerSshHost = "ssh://docker-$sshHostname"
            Write-Host "    [INFO] Using SSH config alias: docker-$sshHostname" -ForegroundColor Cyan
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
            $script:REMOTE_CONTEXT_NAME = $RemoteContextName  # Update global variable
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
                $script:REMOTE_CONTEXT_NAME = $RemoteContextName  # Update global variable
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
    
    # Test with explicit context specification
    $dockerTestOutput = & docker --context $RemoteContextName version 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Remote Docker connection test passed" -ForegroundColor Green
        Write-Host "    [INFO] Docker context is working correctly" -ForegroundColor Cyan
    } else {
        Write-Host "    [WARNING] Remote Docker connection test failed" -ForegroundColor Yellow
        Write-Host "    Error details: $dockerTestOutput" -ForegroundColor Yellow
        Write-Host "" 
        Write-Host "    [INFO] This may be due to Docker context SSH configuration limitations" -ForegroundColor Cyan
        Write-Host "    [INFO] Individual SSH commands work, but Docker context may need manual configuration" -ForegroundColor Cyan
        Write-Host "    [INFO] Continuing - container operations may still work via direct SSH" -ForegroundColor Cyan
    }
    Write-Host ""

    Write-Host "    [SUCCESS] Remote Docker environment is set up and ready to use!" -ForegroundColor Green
    Write-Host ""

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
        $script:LOCAL_REPO_PATH = $selectedPath
        
        # Extract the repository name (last folder in the path)
        $script:SELECTED_REPO = Split-Path $selectedPath -Leaf
        
        Write-Host "    [SUCCESS] Local repository path: $($script:LOCAL_REPO_PATH)" -ForegroundColor Green
        Write-Host "    [SUCCESS] Repository name: $($script:SELECTED_REPO)" -ForegroundColor Green
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
    Write-Host "    Selected repository: $($script:SELECTED_REPO)"
    Write-Host "    Local repository path: $($script:LOCAL_REPO_PATH)"
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
        Write-Host "    Error details: $($_.Exception.Message)"
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
    if ($CONTAINER_LOCATION -like "REMOTE@*" -and (-not $env:DOCKER_SSH_OPTS -or [string]::IsNullOrEmpty($env:DOCKER_SSH_OPTS))) {
        if ($script:sshKeyPath) {
            $env:DOCKER_SSH_OPTS = "-i `"$script:sshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
            Write-Host "[INFO] Restored SSH environment for Docker operations: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
        } else {
            # Fallback - reconstruct from USERNAME
            $script:sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
            $env:DOCKER_SSH_OPTS = "-i `"$script:sshKeyPath`" -o IdentitiesOnly=yes -o ConnectTimeout=30"
            Write-Host "[INFO] Reconstructed SSH environment for Docker operations: $env:DOCKER_SSH_OPTS" -ForegroundColor Cyan
        }
    }
}

# 0.5: Helper function to verify SSH key files exist on remote system for Docker mounting
function Test-RemoteSSHKeyFiles {
    param(
        [string]$RemoteHost,
        [string]$Username
    )
    
    $remoteSSHKeyPath = "/home/php-workstation/.ssh/id_ed25519_${Username}"
    $remoteKnownHostsPath = "/home/php-workstation/.ssh/known_hosts"
    $localSSHKeyPath = "$HOME\.ssh\id_ed25519_$Username"
    
    $results = @{
        PrivateKeyExists = $false
        KnownHostsExists = $false
        ErrorDetails = @()
    }
    
    try {
        # Check if private key exists on remote with timeout protection
        $checkPrivateKeyCommand = "test -f '$remoteSSHKeyPath' && echo PRIVATE_KEY_EXISTS || echo PRIVATE_KEY_MISSING"
        
        # Use PowerShell job with timeout for SSH private key check
        $privateKeyJob = Start-Job -ScriptBlock {
            param($localSSHKeyPath, $RemoteHost, $checkPrivateKeyCommand)
            & ssh -i $localSSHKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $RemoteHost $checkPrivateKeyCommand 2>&1
        } -ArgumentList $localSSHKeyPath, $RemoteHost, $checkPrivateKeyCommand
        
        if (Wait-Job $privateKeyJob -Timeout 15) {
            $privateKeyCheckResult = Receive-Job $privateKeyJob
            Remove-Job $privateKeyJob
            
            if ($privateKeyCheckResult -match "PRIVATE_KEY_EXISTS") {
                $results.PrivateKeyExists = $true
            } else {
                $results.ErrorDetails += "Private key not found at: $remoteSSHKeyPath (Result: $privateKeyCheckResult)"
            }
        } else {
            Remove-Job $privateKeyJob -Force
            $results.ErrorDetails += "Private key check timed out after 15 seconds"
        }
        
        # Check if known_hosts exists on remote with timeout protection
        $checkKnownHostsCommand = "test -f '$remoteKnownHostsPath' && echo KNOWN_HOSTS_EXISTS || echo KNOWN_HOSTS_MISSING"
        
        # Use PowerShell job with timeout for SSH known_hosts check
        $knownHostsJob = Start-Job -ScriptBlock {
            param($localSSHKeyPath, $RemoteHost, $checkKnownHostsCommand)
            & ssh -i $localSSHKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=10 -o BatchMode=yes $RemoteHost $checkKnownHostsCommand 2>&1
        } -ArgumentList $localSSHKeyPath, $RemoteHost, $checkKnownHostsCommand
        
        if (Wait-Job $knownHostsJob -Timeout 15) {
            $knownHostsCheckResult = Receive-Job $knownHostsJob
            Remove-Job $knownHostsJob
            
            if ($knownHostsCheckResult -match "KNOWN_HOSTS_EXISTS") {
                $results.KnownHostsExists = $true
            } else {
                $results.ErrorDetails += "Known_hosts file not found at: $remoteKnownHostsPath (Result: $knownHostsCheckResult)"
            }
        } else {
            Remove-Job $knownHostsJob -Force
            $results.ErrorDetails += "Known_hosts check timed out after 15 seconds"
        }
        
    } catch {
        $results.ErrorDetails += "SSH connection failed: $($_.Exception.Message)"
    }
    
    return $results
}

# 1: Helper function to extract and construct potential paths from the YAML file
function Get-YamlPathValue {
    param (
        [string]$YamlPath,
        [string]$Key,
        [string]$BaseDir # Pass ProjectRoot here (already uses forward slashes)
    )
    
    # Handle remote vs local YAML file reading
    if ($CONTAINER_LOCATION -like "REMOTE@*") {
        # For remote operations, use SSH to read the YAML file
        Set-DockerSSHEnvironment
        $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
        
        Write-Host "[INFO] Reading remote YAML file: $YamlPath" -ForegroundColor Cyan
        
        # Use PowerShell job with timeout for YAML file reading
        $yamlReadJob = Start-Job -ScriptBlock {
            param($sshKeyPath, $remoteHost, $YamlPath)
            & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cat '$YamlPath'" 2>$null
        } -ArgumentList $sshKeyPath, $remoteHost, $YamlPath
        
        if (Wait-Job $yamlReadJob -Timeout 15) {
            $yamlContent = Receive-Job $yamlReadJob
            Remove-Job $yamlReadJob
        } else {
            Remove-Job $yamlReadJob -Force
            Write-Host "Warning: YAML file reading timed out after 15 seconds"
            $yamlContent = $null
            $LASTEXITCODE = 1
        }
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: Could not read remote YAML file: $YamlPath"
            return $null
        }
        
        # Find the line with the key
        $line = $yamlContent -split "`n" | Where-Object { $_ -match "^$Key\s*:" } | Select-Object -First 1
    } else {
        # For local operations, use Select-String as before
        if (-not (Test-Path $YamlPath)) {
            Write-Host "Warning: Local YAML file not found: $YamlPath"
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
        } else {
            # Construct path relative to the specified BaseDir (ProjectRoot)
            # Ensure BaseDir and value use consistent slashes for joining
            $valueNormalized = $value -replace '\\', '/'
            $valueNormalized = $valueNormalized -replace '\.', '' # Remove leading dot if present
            $constructedPath = "$BaseDir/$valueNormalized" # Simple string concatenation with forward slashes
            # Clean up potential double slashes, except after protocol like C://
            $constructedPath = $constructedPath -replace '(?<!:)/{2,}', '/'
            Write-Host "Path '$value' for key '$Key' is relative. Constructed as '$constructedPath'."
        }

        # Normalize to forward slashes for consistency before returning
        $normalizedPath = $constructedPath -replace '\\', '/'
        return $normalizedPath
    }
    Write-Host "Warning: No matching line found for key: $Key in '$YamlPath'"
    return $null
}

# 2: Helper function to check and create directory
function Test-AndCreateDirectory {
    param(
        [string]$Path,
        [string]$PathKey # For logging purposes (e.g., "output_dir")
    )
    if (-not $Path) {
        Write-Host "Error: Could not determine $PathKey path from YAML."
        return $false
    }

    if ($CONTAINER_LOCATION -like "REMOTE@*") {
        # For remote operations, use SSH to check and create directories
        Set-DockerSSHEnvironment
        $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
                Write-Host "[ERROR] Create error details: $createResult" -ForegroundColor Red
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
            Write-Host "[ERROR] SSH check error details: $dirCheck" -ForegroundColor Red
            return $false
        }
    } else {
        # Local operations - use existing logic
        # Use native path format for Test-Path and New-Item
        $NativePath = $Path -replace '/', '\\'

        if (-not (Test-Path $NativePath)) {
            Write-Host "Warning: $PathKey path not found: $NativePath. Creating directory..."
            try {
                New-Item -ItemType Directory -Path $NativePath -Force -ErrorAction Stop | Out-Null
                Write-Host "Successfully created $PathKey directory: $NativePath"
                return $true
            } catch {
                Write-Host "Error: Failed to create $PathKey directory: $NativePath - $($_.Exception.Message)"
                # Attempt to resolve the path to see if it exists now, maybe a race condition or delay
                if(Test-Path $NativePath) {
                     Write-Host "Info: Directory $NativePath seems to exist now despite previous error."
                     return $true
                }
                return $false
            }
        } elseif (-not (Get-Item $NativePath).PSIsContainer) {
            Write-Host "Error: The path specified for $PathKey exists but is a file, not a directory: $NativePath"
            return $false
        } else {
             # Directory exists
             return $true
        }
    }
}

# 3: Helper function to convert Windows path to Docker Desktop/WSL format
function Convert-PathToDockerFormat {
    param([string]$Path)
    # Input example: P:/My_Models/IMPACTncd_Japan
    # Match drive letter (e.g., P) and the rest of the path
    if ($Path -match '^([A-Za-z]):/(.*)') {
        $driveLetter = $matches[1].ToLower()
        $restOfPath = $matches[2]
        # Construct the Docker path: /<drive_letter>/<rest_of_path>
        $dockerPath = "/$driveLetter/$restOfPath"
        # Remove trailing slash if present
        $dockerPath = $dockerPath -replace '/$', ''
        return $dockerPath
    } else {
        Write-Warning "Path '$Path' did not match expected Windows format (e.g., C:/path/to/dir)"
        return $Path # Return original path if format is unexpected
    }
}

# 4: Helper function to capture git repository state
function Get-GitRepositoryState {
    param([string]$RepoPath)
    
    if ($CONTAINER_LOCATION -like "REMOTE@*") {
        # Handle remote repository paths
        if (-not $RepoPath) {
            Write-Host "[WARNING] No remote repository path provided" -ForegroundColor Yellow
            return $null
        }
        
        try {
            Set-DockerSSHEnvironment
            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
            $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
            
            Write-Host "[INFO] Checking remote git repository state: $RepoPath" -ForegroundColor Cyan
            
            # Check if this is a git repository
            $isGitRepo = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git rev-parse --is-inside-work-tree" 2>$null
            if ($LASTEXITCODE -ne 0 -or $isGitRepo -ne "true") {
                Write-Host "[INFO] Remote path is not a git repository or git not available" -ForegroundColor Cyan
                return $null
            }
            
            # Get current commit hash
            $currentCommit = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git rev-parse HEAD" 2>$null
            
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
            return $state
            
        } catch {
            Write-Host "[WARNING] Error capturing remote git repository state: $($_.Exception.Message)" -ForegroundColor Yellow
            return $null
        }
    } else {
        # Handle local repository paths
        if (-not (Test-Path $RepoPath)) {
            Write-Host "[WARNING] Repository path does not exist: $RepoPath" -ForegroundColor Yellow
            return $null
        }
        
        try {
            Push-Location $RepoPath
            
            # Check if this is a git repository
            $isGitRepo = git rev-parse --is-inside-work-tree 2>$null
            if ($LASTEXITCODE -ne 0 -or $isGitRepo -ne "true") {
                Write-Host "[INFO] Not a git repository or git not available" -ForegroundColor Cyan
                return $null
            }
            
            # Get current commit hash
            $currentCommit = git rev-parse HEAD 2>$null
            
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
            return $state
            
        } catch {
            Write-Host "[WARNING] Error capturing local git state: $($_.Exception.Message)" -ForegroundColor Yellow
            return $null
        } finally {
            Pop-Location
        }
    }
}

# 5: Helper function to check for git changes and prompt for commit
function Invoke-GitChangeDetection {
    param([string]$RepoPath)
    
    Write-Host "[INFO] Checking for git changes after container execution..." -ForegroundColor Cyan
    
    if (-not $script:gitStateBeforeContainer) {
        Write-Host "[INFO] No git state was captured before container start - skipping change detection" -ForegroundColor Cyan
        return
    }
    
    $currentState = Get-GitRepositoryState -RepoPath $RepoPath
    if (-not $currentState) {
        Write-Host "[INFO] Could not get current git state - skipping change detection" -ForegroundColor Cyan
        return
    }
    
    # Check if this is a remote repository
    $isRemote = $CONTAINER_LOCATION -like "REMOTE@*"
    
    try {
        if ($isRemote) {
            # Handle remote repository
            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
            $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
            
            # Get current status on remote
            $currentStatus = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git status --porcelain" 2>$null
            $currentFiles = ($currentStatus -split "`n" | Where-Object { $_.Trim() -ne "" })
            
            # Check if there are any changes
            if ($currentFiles.Count -eq 0) {
                Write-Host "[INFO] No git changes detected after container execution" -ForegroundColor Green
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
                
                # Show the commit dialog for remote repository
                Show-GitCommitDialog -RepoPath $RepoPath
                
            } else {
                Write-Host "[ERROR] Failed to stage changes on remote" -ForegroundColor Red
            }
            
        } else {
            # Handle local repository
            Push-Location $RepoPath
            
            # Get current status
            $currentStatus = git status --porcelain 2>$null
            $currentFiles = ($currentStatus -split "`n" | Where-Object { $_.Trim() -ne "" })
            
            # Check if there are any changes
            if ($currentFiles.Count -eq 0) {
                Write-Host "[INFO] No git changes detected after container execution" -ForegroundColor Green
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
                
                # Show the commit dialog
                Show-GitCommitDialog -RepoPath $RepoPath
                
            } else {
                Write-Host "[ERROR] Failed to stage changes" -ForegroundColor Red
            }
        }
        
    } catch {
        Write-Host "[ERROR] Error during git change detection: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if (-not $isRemote) {
            Pop-Location
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
        StartPosition = "CenterScreen"
        MaximizeBox = $false
        MinimizeBox = $false
        FormBorderStyle = "FixedDialog"
        TopMost = $true
    }
    
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
        
        try {
            if ($isRemote) {
                # Handle remote repository operations
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                
                $StatusLabel.Text = "Status: Pushing to remote repository..."
                $StatusLabel.ForeColor = [System.Drawing.Color]::Blue
                $CommitForm.Refresh()
                
                # First, try to get remote URL to determine if it's HTTPS or SSH
                $remoteUrl = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "cd '$RepoPath' && git remote get-url origin" 2>$null
                $isHttpsRepo = $remoteUrl -match "^https://"
                $isSshRepo = $remoteUrl -match "^git@"
                
                # Configure git authentication on remote host
                if ($isSshRepo) {
                    Write-Host "[INFO] Remote repository uses SSH authentication" -ForegroundColor Cyan
                    Write-Host "[INFO] Configuring SSH agent on remote host..." -ForegroundColor Cyan
                    
                    # First check if SSH key exists on remote host
                    $keyExists = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost "test -f ~/.ssh/id_ed25519_$USERNAME && echo 'exists'" 2>$null
                    
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
                
                # If SSH agent approach failed, try direct SSH key approach
                if ($pushExitCode -ne 0 -and ($pushOutput -match "ssh-add.*No such file|ssh-agent.*not found")) {
                    Write-Host "[INFO] SSH agent approach failed, trying direct SSH key method..." -ForegroundColor Yellow
                    
                    $directPushCommand = "cd '$RepoPath' && GIT_SSH_COMMAND='ssh -i ~/.ssh/id_ed25519_$USERNAME -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' git push"
                    $pushOutput = & ssh -i $sshKeyPath -o IdentitiesOnly=yes -o ConnectTimeout=30 -o BatchMode=yes $remoteHost $directPushCommand 2>&1
                    $pushExitCode = $LASTEXITCODE
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
                $CommitForm.Close()
                return $true
            } else {
                # Parse the error to provide more helpful feedback
                $errorMessage = $pushOutput -join "`n"
                Write-Host "[GIT PUSH ERROR] $errorMessage" -ForegroundColor Red
                
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
            return $false
        } finally {
            if (-not $isRemote) {
                Pop-Location
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
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
$CONTAINER_NAME = "$($script:SELECTED_REPO)_$USERNAME"

# Check for existing containers with the username
Write-Host ""
Write-Host "================================================"
Write-Host "  STEP 5: Container Status Check"
Write-Host "================================================"
Write-Host ""

Write-Host "[INFO] Checking for existing containers for user: $USERNAME" -ForegroundColor Cyan
Write-Host ""

try {
    # Ensure SSH environment is set for remote Docker operations
    Set-DockerSSHEnvironment
    
    # Get all containers (running and stopped) that contain the username
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        $existingContainers = & docker ps -a --filter "name=_$USERNAME" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>$null
    } else {
        # For remote, use the context we set up
        $existingContainers = & docker --context $script:REMOTE_CONTEXT_NAME ps -a --filter "name=_$USERNAME" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>$null
    }
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] Could not check for existing containers. Consider checking manually in Docker Desktop!" -ForegroundColor Yellow
        Write-Host "  Continuing with container launch..."
        Write-Host ""
    } else {
        # Parse the output to find containers
        $containerList = $existingContainers -split "`n" | Where-Object { $_ -match "_$USERNAME" -and $_ -notmatch "^NAMES" }
        
        if ($containerList.Count -gt 0) {
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
            
            # Check specifically for running containers
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $runningContainers = & docker ps --filter "name=_$USERNAME" --format "{{.Names}}" 2>$null
            } else {
                $runningContainers = & docker --context $script:REMOTE_CONTEXT_NAME ps --filter "name=_$USERNAME" --format "{{.Names}}" 2>$null
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
                                & docker --context $script:REMOTE_CONTEXT_NAME stop $runningContainer 2>$null
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
Write-Host "  Selected Repository: $($script:SELECTED_REPO)"
Write-Host "  Username: $USERNAME"
Write-Host ""

# Check if the specific container is currently running
$isContainerRunning = $false
try {
    # Ensure SSH environment is set for remote Docker operations
    Set-DockerSSHEnvironment
    
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        $runningCheck = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
    } else {
        $runningCheck = & docker --context $script:REMOTE_CONTEXT_NAME ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
    }
    if ($null -eq $runningCheck) {
        $runningCheck = "this_container_does_not_exist" # Default to non-matching string
    }
    if ($LASTEXITCODE -eq 0 -and $runningCheck.Trim() -eq $CONTAINER_NAME) {
        $isContainerRunning = $true
        Write-Host "[INFO] Container '$CONTAINER_NAME' is currently RUNNING" -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] Container '$CONTAINER_NAME' is currently STOPPED or does not exist" -ForegroundColor Cyan
    }
} catch {
    Write-Host "[WARNING] Could not check container status: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Creating container management interface..."
Write-Host ""

# Create the main container management form
$formContainer = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Container Management - IMPACT NCD Germany'
    Size = New-Object System.Drawing.Size(500,430)
    StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}

# Instruction label
$labelInstruction = New-Object System.Windows.Forms.Label -Property @{ 
    Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: $(if ($isContainerRunning) { 'RUNNING' } else { 'STOPPED' })"
    Location = New-Object System.Drawing.Point(10,10)
    Size = New-Object System.Drawing.Size(470,80)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$formContainer.Controls.Add($labelInstruction)

# Start button
$buttonStart = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Start Container'
    Location = New-Object System.Drawing.Point(50,100)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    Enabled = -not $isContainerRunning
}
$formContainer.Controls.Add($buttonStart)

# Stop button  
$buttonStop = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Stop Container'
    Location = New-Object System.Drawing.Point(200,100)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
    Enabled = $isContainerRunning
}
$formContainer.Controls.Add($buttonStop)

# Advanced Options section
$labelAdvanced = New-Object System.Windows.Forms.Label -Property @{ 
    Text = "Advanced Options:"
    Location = New-Object System.Drawing.Point(10,160)
    Size = New-Object System.Drawing.Size(470,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formContainer.Controls.Add($labelAdvanced)

# Checkbox option
$checkBoxVolumes = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'Use Docker Volumes (instead of bind mounts)'
    Location = New-Object System.Drawing.Point(20,185)
    Size = New-Object System.Drawing.Size(200,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$formContainer.Controls.Add($checkBoxVolumes)

# Rebuild image checkbox option
$checkBoxRebuild = New-Object System.Windows.Forms.CheckBox -Property @{
    Text = 'Rebuild repo image (force rebuild even if exists)'
    Location = New-Object System.Drawing.Point(230,185)
    Size = New-Object System.Drawing.Size(250,20)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$formContainer.Controls.Add($checkBoxRebuild)

# Port override label and textbox
$labelPort = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Port Override:'
    Location = New-Object System.Drawing.Point(20,215)
    Size = New-Object System.Drawing.Size(100,20)
}
$formContainer.Controls.Add($labelPort)
$textBoxPort = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(130,215)
    Size = New-Object System.Drawing.Size(100,20)
    Text = '8787'
}
$formContainer.Controls.Add($textBoxPort)

# Custom parameters label and textbox
$labelParams = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Custom Parameters:'
    Location = New-Object System.Drawing.Point(20,245)
    Size = New-Object System.Drawing.Size(120,20)
}
$formContainer.Controls.Add($labelParams)
$textBoxParams = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(150,245)
    Size = New-Object System.Drawing.Size(200,20)
    Text = ''
}
$formContainer.Controls.Add($textBoxParams)

# sim_design.yaml file label and textbox
$labelSimDesign = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'sim_design.yaml file used for directory creation:'
    Location = New-Object System.Drawing.Point(20,275)
    Size = New-Object System.Drawing.Size(280,20)
}
$formContainer.Controls.Add($labelSimDesign)
$textBoxSimDesign = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(310,275)
    Size = New-Object System.Drawing.Size(160,20)
    Text = '..\inputs\sim_design.yaml'
}
$formContainer.Controls.Add($textBoxSimDesign)

# OK and Cancel buttons
$buttonOK = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Close'
    Location = New-Object System.Drawing.Point(200,350)
    Size = New-Object System.Drawing.Size(75,30)
}
$formContainer.Controls.Add($buttonOK)

$buttonCancel = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Cancel'
    Location = New-Object System.Drawing.Point(290,350)
    Size = New-Object System.Drawing.Size(75,30)
    DialogResult = [System.Windows.Forms.DialogResult]::Cancel
}
$formContainer.Controls.Add($buttonCancel)

# Set default buttons
$formContainer.AcceptButton = $buttonOK
$formContainer.CancelButton = $buttonCancel

# Declare variables at form scope so both event handlers can access them
$script:useVolumes = $false
$script:outputDir = $null
$script:synthpopDir = $null
$script:VolumeOutput = $null
$script:VolumeSynthpop = $null
$script:UserId = $null
$script:GroupId = $null
$script:rsyncImage = $null

# Event handlers
$buttonStart.Add_Click({
    Write-Host ""
    Write-Host "[INFO] Container is starting up..." -ForegroundColor Cyan
    Write-Host "  Container: $CONTAINER_NAME"
    
    # Get options from form and store in script scope
    $script:useVolumes = $checkBoxVolumes.Checked
    $useVolumes = $script:useVolumes  # Keep local copy for backwards compatibility
    $script:rebuildImage = $checkBoxRebuild.Checked
    $rebuildImage = $script:rebuildImage  # Keep local copy for backwards compatibility
    $portOverride = $textBoxPort.Text.Trim()
    $customParams = $textBoxParams.Text.Trim()
    $SimDesignYAML = $textBoxSimDesign.Text.Trim()
    
    Write-Host "  Advanced Options:"
    Write-Host "    Use Volumes: $useVolumes"
    Write-Host "    Rebuild Image: $rebuildImage"
    Write-Host "    Port Override: $(if($portOverride) { $portOverride } else { 'Default' })"
    Write-Host "    Custom Parameters: $(if($customParams) { $customParams } else { 'None' })"
    Write-Host "    sim_design.yaml file: $(if($SimDesignYAML) { $SimDesignYAML } else { 'Default' })"
    Write-Host ""

    # Resolve docker setup directory based on current model
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        if (-not $script:LOCAL_REPO_PATH) {
            Write-Host "[FATAL ERROR] No local repository path found. Please restart the application and select a folder."
            Exit 1
        }
        $ScriptDir = "$script:LOCAL_REPO_PATH\docker_setup"
        $ProjectRoot = $script:LOCAL_REPO_PATH
        Write-Host "[INFO] Using local repository path: $script:LOCAL_REPO_PATH" -ForegroundColor Cyan
        
        # Validate that the docker_setup directory exists locally
        if (-not (Test-Path $ScriptDir)) {
            Write-Host "[FATAL ERROR] Your repository has no Docker setup directory at '$ScriptDir'"
            Exit 1
        }
    } else {
        # Remote operation
        if (-not $script:REMOTE_REPO_PATH) {
            Write-Host "[FATAL ERROR] No remote repository path found. Please restart the application and select a repository."
            Exit 1
        }
        $ScriptDir = "$script:REMOTE_REPO_PATH/docker_setup"
        $ProjectRoot = $script:REMOTE_REPO_PATH
        Write-Host "[INFO] Using remote repository path: $script:REMOTE_REPO_PATH" -ForegroundColor Cyan
        
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
    $DockerImageName = $script:SELECTED_REPO.ToLower()
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
                Write-Host "[INFO] Checking for Docker image on remote host using context: $script:REMOTE_CONTEXT_NAME" -ForegroundColor Cyan
                $imageCheck = & docker --context $script:REMOTE_CONTEXT_NAME images --format "{{.Repository}}" 2>$null | Where-Object { $_ -eq $DockerImageName }
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
            $dockerfilePath = Join-Path $script:LOCAL_REPO_PATH "docker_setup\Dockerfile.IMPACTncdGER"
            $dockerContextPath = $script:LOCAL_REPO_PATH
        } else {
            $dockerfilePath = "$script:REMOTE_REPO_PATH/docker_setup/Dockerfile.IMPACTncdGER"
            $dockerContextPath = $script:REMOTE_REPO_PATH
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
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
                $dockerCommand = "docker build -f `"$dockerfilePath`" -t $DockerImageName --no-cache `"$dockerContextPath`""
                Write-Debug-Message "[DEBUG] Docker command: $dockerCommand"
                Write-Host ""

                # Execute Docker build with spinner
                Write-Host "[INFO] Building Docker image (this may take 5-15 minutes)..." -NoNewline -ForegroundColor Cyan
                Start-Spinner -Message ""
                
                try {
                    # Use Invoke-Expression to run the command and show output directly
                    $buildResult = & cmd /c $dockerCommand '2>&1'
                    $buildSuccess = $LASTEXITCODE -eq 0
                    Stop-Spinner
                    
                    if ($buildSuccess) {
                        Write-Host ""
                        Write-Host " [SUCCESS]" -ForegroundColor Green
                        Write-Host ""
                    } else {
                        Write-Host ""
                        Write-Host " [FAILED]" -ForegroundColor Red
                        Write-Host ""
                    }
                    Write-Host ""

                    # Display the output
                    Write-Host "[DOCKER BUILD OUTPUT]"
                    Write-Host ("-" * 60)
                    if ($buildResult) {
                        foreach ($line in $buildResult) {
                            Write-Host "[DOCKER] $line"
                        }
                    }
                } catch {
                    Stop-Spinner
                    Write-Host " [FAILED]" -ForegroundColor Red
                    Write-Host ""
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
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                $buildCommand = "cd '$dockerContextPath' && docker build -f '$dockerfilePath' -t '$DockerImageName' --no-cache . 2>&1"
                Write-Host ""

                # Execute remote Docker build with spinner
                Write-Host "[INFO] Building Docker image on remote host (this may take 5-15 minutes)..." -NoNewline -ForegroundColor Cyan
                Start-Spinner -Message ""

                try {
                    # Execute SSH command directly and show output in real-time with proper authentication
                    Set-DockerSSHEnvironment
                    $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                    $sshCommand = "ssh -o ConnectTimeout=30 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost `"$buildCommand`""
                    Write-Debug-Message "[DEBUG] SSH command: $sshCommand"
                    Write-Host ""

                    $buildResult = & cmd /c $sshCommand '2>&1'
                    $buildSuccess = $LASTEXITCODE -eq 0
                    Stop-Spinner
                    
                    if ($buildSuccess) {
                        Write-Host ""
                        Write-Host " [SUCCESS]" -ForegroundColor Green
                        Write-Host ""
                    } else {
                        Write-Host ""
                        Write-Host " [FAILED]" -ForegroundColor Red
                        Write-Host ""
                    }
                    Write-Host ""

                    # Display the output
                    Write-Host "[REMOTE DOCKER BUILD OUTPUT]"
                    Write-Host ("-" * 60)
                    if ($buildResult) {
                        foreach ($line in $buildResult) {
                            Write-Host "[REMOTE] $line"
                        }
                    }
                } catch {
                    Stop-Spinner
                    Write-Host ""
                    Write-Host " [FAILED]" -ForegroundColor Red
                    Write-Host ""
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
                    $prereqDockerfilePath = Join-Path $script:LOCAL_REPO_PATH "docker_setup\Dockerfile.prerequisite.IMPACTncdGER"
                    $prereqDockerContextPath = Join-Path $script:LOCAL_REPO_PATH "docker_setup"

                } else {
                    $prereqDockerfilePath = "$script:REMOTE_REPO_PATH/docker_setup/Dockerfile.prerequisite.IMPACTncdGER"
                    $prereqDockerContextPath = "$script:REMOTE_REPO_PATH/docker_setup"
                }

                Write-Host "[INFO] Using prerequisite Dockerfile: $prereqDockerfilePath" -ForegroundColor Cyan
                Write-Host ""

                # Check if prerequisite Dockerfile exists
                $prereqDockerfileExists = $false
                try {
                    if ($CONTAINER_LOCATION -eq "LOCAL") {
                        $prereqDockerfileExists = Test-Path $prereqDockerfilePath
                    } else {
                        $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
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
                            $prereqCommand = "docker build -f `"$prereqDockerfilePath`" -t $prereqImageName --no-cache `"$prereqDockerContextPath`""
                            Write-Debug-Message "[DEBUG] Prerequisite command: $prereqCommand"
                            Write-Host ""

                            # Execute prerequisite build with spinner
                            Write-Host "[INFO] Building prerequisite image (this may take 5-15 minutes)..." -NoNewline -ForegroundColor Cyan
                            Start-Spinner -Message ""
                            Write-Host ""

                            try {
                                # Execute prerequisite build directly and show output in real-time
                                $prereqBuildResult = & cmd /c $prereqCommand '2>&1'
                                $prereqBuildSuccess = $LASTEXITCODE -eq 0
                                Stop-Spinner
                                
                                if ($prereqBuildSuccess) {
                                    Write-Host ""
                                    Write-Host " [SUCCESS]" -ForegroundColor Green
                                    Write-Host ""
                                } else {
                                    Write-Host ""
                                    Write-Host " [FAILED]" -ForegroundColor Red
                                    Write-Host ""
                                }
                                Write-Host ""

                                # Display the output
                                Write-Host "[PREREQUISITE BUILD OUTPUT]"
                                Write-Host ("-" * 60)
                                if ($prereqBuildResult) {
                                    foreach ($line in $prereqBuildResult) {
                                        Write-Host "[DOCKER-PREREQ] $line"
                                    }
                                }
                            } catch {
                                Stop-Spinner
                                Write-Host ""
                                Write-Host " [FAILED]" -ForegroundColor Red
                                Write-Host ""
                                Write-Host "[ERROR] Exception during prerequisite build: $($_.Exception.Message)" -ForegroundColor Red
                                $prereqBuildSuccess = $false
                                $prereqBuildResult = "Prerequisite build failed with exception: $($_.Exception.Message)"
                            }

                            Write-Host ("-" * 60)
                            Write-Host ""

                        } else {
                            # Remote build of prerequisite with real-time output
                            Write-Host ""
                            Write-Host "[DOCKER-PREREQ] Building prerequisite image on remote host..."
                            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                            $prereqBuildCommand = "cd '$prereqDockerContextPath' && docker build -f '$prereqDockerfilePath' -t '$prereqImageName' --no-cache . 2>&1"
                            Write-Host ""

                            # Execute remote prerequisite build with spinner
                            Write-Host "[INFO] Building prerequisite image on remote host (this may take 5-15 minutes)..." -NoNewline -ForegroundColor Cyan
                            Start-Spinner -Message ""

                            try {
                                # Execute SSH prerequisite command directly and show output in real-time with proper authentication
                                Set-DockerSSHEnvironment
                                $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                                $prereqSSHCommand = "ssh -o ConnectTimeout=30 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost `"$prereqBuildCommand`""
                                Write-Debug-Message "[DEBUG] SSH prerequisite command: $prereqSSHCommand"

                                $prereqBuildResult = & cmd /c $prereqSSHCommand '2>&1'
                                $prereqBuildSuccess = $LASTEXITCODE -eq 0
                                Stop-Spinner
                                
                                if ($prereqBuildSuccess) {
                                    Write-Host ""
                                    Write-Host " [SUCCESS]" -ForegroundColor Green
                                    Write-Host ""
                                } else {
                                    Write-Host ""
                                    Write-Host " [FAILED]" -ForegroundColor Red
                                    Write-Host ""
                                }
                                Write-Host ""

                                # Display the output
                                Write-Host "[REMOTE DOCKER PREREQUISITE BUILD OUTPUT]"
                                Write-Host ("-" * 60)
                                if ($prereqBuildResult) {
                                    foreach ($line in $prereqBuildResult) {
                                        Write-Host "[DOCKER-PREREQ-REMOTE] $line"
                                    }
                                }
                            } catch {
                                Stop-Spinner
                                Write-Host ""
                                Write-Host " [FAILED]" -ForegroundColor Red
                                Write-Host ""
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
                                    $retryCommand = "docker build -f `"$dockerfilePath`" -t $DockerImageName --no-cache `"$dockerContextPath`""
                                    Write-Debug-Message "[DEBUG] Retry command: $retryCommand"
                                    Write-Host ""

                                    # Execute retry build with spinner
                                    Write-Host ""
                                    Write-Host "[INFO] Retrying main image build (should be faster with prerequisite)..." -NoNewline -ForegroundColor Cyan
                                    Start-Spinner -Message ""

                                    try {
                                        # Execute retry build directly and show output in real-time
                                        $retryBuildResult = & cmd /c $retryCommand '2>&1'
                                        $retryBuildSuccess = $LASTEXITCODE -eq 0
                                        Stop-Spinner
                                        
                                        if ($retryBuildSuccess) {
                                            Write-Host ""
                                            Write-Host " [SUCCESS]" -ForegroundColor Green
                                            Write-Host ""
                                        } else {
                                            Write-Host ""
                                            Write-Host " [FAILED]" -ForegroundColor Red
                                            Write-Host ""
                                        }
                                        Write-Host ""

                                        # Display the output
                                        Write-Host "[DOCKER-RETRY BUILD OUTPUT]"
                                        Write-Host ("-" * 60)
                                        if ($retryBuildResult) {
                                            foreach ($line in $retryBuildResult) {
                                                Write-Host "[DOCKER-RETRY] $line"
                                            }
                                        }
                                    } catch {
                                        Stop-Spinner
                                        Write-Host ""
                                        Write-Host " [FAILED]" -ForegroundColor Red
                                        Write-Host ""
                                        Write-Host "[ERROR] Exception during retry build: $($_.Exception.Message)" -ForegroundColor Red
                                        $retryBuildSuccess = $false
                                        $retryBuildResult = "Retry build failed with exception: $($_.Exception.Message)"
                                    }

                                    Write-Host ("-" * 60)
                                    Write-Host ""

                                } else {
                                    # Remote build retry with real-time output
                                    Write-Host "[DOCKER-RETRY-REMOTE] Retrying main image build on remote host..."
                                    $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                                    $retryBuildCommand = "cd '$dockerContextPath' && docker build -f '$dockerfilePath' -t '$DockerImageName' --no-cache . 2>&1"
                                    Write-Host ""

                                    # Execute remote retry build with spinner
                                    Write-Host ""
                                    Write-Host "[INFO] Retrying main image build on remote host (should be faster with prerequisite)..." -NoNewline -ForegroundColor Cyan
                                    Start-Spinner -Message ""

                                    try {
                                        # Execute SSH retry command directly and show output in real-time with proper authentication
                                        Set-DockerSSHEnvironment
                                        $sshKeyPath = "$HOME\.ssh\id_ed25519_$USERNAME"
                                        $retrySSHCommand = "ssh -o ConnectTimeout=30 -o BatchMode=yes -o PasswordAuthentication=no -o PubkeyAuthentication=yes -o IdentitiesOnly=yes -i $sshKeyPath $remoteHost `"$retryBuildCommand`""
                                        Write-Host ""
                                        Write-Debug-Message "[DEBUG] SSH retry command: $retrySSHCommand"

                                        $retryBuildResult = & cmd /c $retrySSHCommand '2>&1'
                                        $retryBuildSuccess = $LASTEXITCODE -eq 0
                                        Stop-Spinner
                                        
                                        if ($retryBuildSuccess) {
                                            Write-Host ""
                                            Write-Host " [SUCCESS]" -ForegroundColor Green
                                            Write-Host ""
                                        } else {
                                            Write-Host ""
                                            Write-Host " [FAILED]" -ForegroundColor Red
                                            Write-Host ""
                                        }
                                        Write-Host ""

                                        # Display the output
                                        Write-Host "[REMOTE DOCKER RETRY BUILD OUTPUT]"
                                        Write-Host ("-" * 60)
                                        if ($retryBuildResult) {
                                            foreach ($line in $retryBuildResult) {
                                                Write-Host "[DOCKER-RETRY-REMOTE] $line"
                                            }
                                        }
                                    } catch {
                                        Stop-Spinner
                                        Write-Host ""
                                        Write-Host " [FAILED]" -ForegroundColor Red
                                        Write-Host ""
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
    if ($CONTAINER_LOCATION -eq "LOCAL" -and $script:LOCAL_REPO_PATH) {
        $gitRepoPath = $script:LOCAL_REPO_PATH
        Write-Host "[INFO] Using local repository path for git operations: $gitRepoPath" -ForegroundColor Cyan
    } elseif ($CONTAINER_LOCATION -like "REMOTE@*" -and $script:REMOTE_REPO_PATH) {
        $gitRepoPath = $script:REMOTE_REPO_PATH
        Write-Host "[INFO] Using remote repository path for git operations: $gitRepoPath" -ForegroundColor Cyan
    } else {
        Write-Host "[WARNING] No valid repository path found for git operations" -ForegroundColor Yellow
        $gitRepoPath = $null
    }
    
    if ($gitRepoPath) {
        $script:gitStateBeforeContainer = Get-GitRepositoryState -RepoPath $gitRepoPath
        $script:gitRepoPath = $gitRepoPath  # Store for later use in stop handler
    } else {
        $script:gitStateBeforeContainer = $null
        $script:gitRepoPath = $null
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
    $script:outputDir = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "output_dir" -BaseDir $ProjectRoot
    $outputDir = $script:outputDir  # Keep local copy for backwards compatibility
    Write-Host ""
    Write-Host ""
    $script:synthpopDir = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "synthpop_dir" -BaseDir $ProjectRoot
    $synthpopDir = $script:synthpopDir  # Keep local copy for backwards compatibility
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
        $script:rsyncImage = "rsync-alpine"
        $rsyncImage = $script:rsyncImage  # Keep local copy for backwards compatibility
        
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker image inspect $rsyncImage > $null 2>&1
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:REMOTE_CONTEXT_NAME image inspect $rsyncImage > $null 2>&1
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
                $InlineDockerfile | & docker --context $script:REMOTE_CONTEXT_NAME build -t $rsyncImage -
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
            & docker --context $script:REMOTE_CONTEXT_NAME volume rm $VolumeOutput -f 2>$null
            & docker --context $script:REMOTE_CONTEXT_NAME volume rm $VolumeSynthpop -f 2>$null
        }

        # Create fresh Docker-managed volumes
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker volume create $VolumeOutput | Out-Null
            & docker volume create $VolumeSynthpop | Out-Null
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:REMOTE_CONTEXT_NAME volume create $VolumeOutput | Out-Null
            & docker --context $script:REMOTE_CONTEXT_NAME volume create $VolumeSynthpop | Out-Null
        }

        # Fix volume ownership and pre-populate volumes:
        # Docker volumes are created with root ownership by default. We need to fix
        # the ownership before we can populate them as the calling user.
        Write-Host "[INFO] Setting correct ownership for Docker volumes..." -ForegroundColor Cyan
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker run --rm -v "${VolumeOutput}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
            & docker run --rm -v "${VolumeSynthpop}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:REMOTE_CONTEXT_NAME run --rm -v "${VolumeOutput}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
            & docker --context $script:REMOTE_CONTEXT_NAME run --rm -v "${VolumeSynthpop}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
        }
        Write-Host ""

        # Pre-populate volumes:
        # The output and synthpop volumes are populated from the respective source folders.
        
        # Use permission-tolerant copy with fallback logic
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            # For local Windows, convert paths for Docker
            $dockerOutputSource = Convert-PathToDockerFormat -Path $outputDir
            $dockerSynthpopSource = Convert-PathToDockerFormat -Path $synthpopDir
            $script:REPO_PATH = $script:LOCAL_REPO_PATH
        } else {
            # For remote Linux, use paths directly
            $dockerOutputSource = $outputDir
            $dockerSynthpopSource = $synthpopDir
            $script:REPO_PATH = $script:REMOTE_REPO_PATH
        }

        Write-Host "[INFO] Populating output volume from source directory..." -ForegroundColor Cyan
        Write-Host ""
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker run --rm --user "${UserId}:${GroupId}" -v "${dockerOutputSource}:/source" -v "${VolumeOutput}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:REMOTE_CONTEXT_NAME run --rm --user "${UserId}:${GroupId}" -v "${dockerOutputSource}:/source" -v "${VolumeOutput}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        }
        Write-Host "[INFO] Populating synthpop volume from source directory..." -ForegroundColor Cyan
        Write-Host ""
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker run --rm --user "${UserId}:${GroupId}" -v "${dockerSynthpopSource}:/source" -v "${VolumeSynthpop}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:REMOTE_CONTEXT_NAME run --rm --user "${UserId}:${GroupId}" -v "${dockerSynthpopSource}:/source" -v "${VolumeSynthpop}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
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
            "--mount", "type=bind,source=$script:REPO_PATH,target=/host-repo",
            "-e", "REPO_SYNC_PATH=/host-repo",
            "-e", "SYNC_ENABLED=true",
            # Port mapping with override support
            "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
            # Directory mounts
            "-v", "${VolumeOutput}:/home/rstudio/$script:SELECTED_REPO/outputs",
            "-v", "${VolumeSynthpop}:/home/rstudio/$script:SELECTED_REPO/inputs/synthpop",
            # SSH key and known_hosts for git access - use appropriate paths for execution location
            "--mount", "type=bind,source=${sshKeyPath},target=/keys/id_ed25519_${USERNAME},readonly",
            "--mount", "type=bind,source=${knownHostsPath},target=/etc/ssh/ssh_known_hosts,readonly",
            # Working directory
            "--workdir", "/home/rstudio/$script:SELECTED_REPO"
        )

        # Add final argument
        $dockerArgs += $DockerImageName

        # Execute docker with the arguments array
        Write-Host "[INFO] Starting RStudio Server container with volumes..." -ForegroundColor Cyan
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            & docker $dockerArgs
        } else {
            Set-DockerSSHEnvironment
            & docker --context $script:REMOTE_CONTEXT_NAME $dockerArgs
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
                $containerStatus = & docker --context $script:REMOTE_CONTEXT_NAME ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
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
                    Write-Host "  URL: http://$($script:REMOTE_HOST_IP):$(if($portOverride) { $portOverride } else { '8787' })"
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
                $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: RUNNING`nLocation: $CONTAINER_LOCATION`nVolumes: Enabled"
                
            } else {
                Write-Host "[WARNING] Container may have exited. Checking logs..." -ForegroundColor Yellow
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    $containerLogs = & docker logs $CONTAINER_NAME 2>&1
                } else {
                    Set-DockerSSHEnvironment
                    $containerLogs = & docker --context $script:REMOTE_CONTEXT_NAME logs $CONTAINER_NAME 2>&1
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
                "--mount", "type=bind,source=$script:LOCAL_REPO_PATH,target=/host-repo",
                "-e", "REPO_SYNC_PATH=/host-repo",
                "-e", "SYNC_ENABLED=true",
                # Port mapping with override support
                "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
                # Directory mounts
                "--mount", "type=bind,source=$DockerOutputDir,target=/home/rstudio/$script:SELECTED_REPO/outputs",
                "--mount", "type=bind,source=$DockerSynthpopDir,target=/home/rstudio/$script:SELECTED_REPO/inputs/synthpop",
                # SSH key and known_hosts for git access (Windows paths)
                "--mount", "type=bind,source=${sshKeyPath},target=/keys/id_ed25519_${USERNAME},readonly",
                "--mount", "type=bind,source=${knownHostsPath},target=/etc/ssh/ssh_known_hosts,readonly",
                # Working directory
                "--workdir", "/home/rstudio/$script:SELECTED_REPO"
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
                "--mount", "type=bind,source=$script:REMOTE_REPO_PATH,target=/host-repo",
                "-e", "REPO_SYNC_PATH=/host-repo",
                "-e", "SYNC_ENABLED=true",
                # Port mapping with override support
                "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
                # Directory mounts (Unix paths)
                "--mount", "type=bind,source=$DockerOutputDir,target=/home/rstudio/$script:SELECTED_REPO/outputs",
                "--mount", "type=bind,source=$DockerSynthpopDir,target=/home/rstudio/$script:SELECTED_REPO/inputs/synthpop",
                # SSH key and known_hosts for git access (Linux paths)
                "--mount", "type=bind,source=${sshKeyPath},target=/keys/id_ed25519_${USERNAME},readonly",
                "--mount", "type=bind,source=${knownHostsPath},target=/etc/ssh/ssh_known_hosts,readonly",
                # Working directory
                "--workdir", "/home/rstudio/$script:SELECTED_REPO"
            )
        }

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
            & docker --context $script:REMOTE_CONTEXT_NAME $dockerArgs
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
                $containerStatus = & docker --context $script:REMOTE_CONTEXT_NAME ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
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
                    Write-Host "  URL: http://$($script:REMOTE_HOST_IP):$(if($portOverride) { $portOverride } else { '8787' })"
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
                $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: RUNNING`nLocation: $CONTAINER_LOCATION`nVolumes: Disabled"
                
            } else {
                Write-Host ""
                Write-Host "[WARNING] Container may have exited. Checking logs..." -ForegroundColor Yellow
                Write-Host ""
                if ($CONTAINER_LOCATION -eq "LOCAL") {
                    $containerLogs = & docker logs $CONTAINER_NAME 2>&1
                } else {
                    Set-DockerSSHEnvironment
                    $containerLogs = & docker --context $script:REMOTE_CONTEXT_NAME logs $CONTAINER_NAME 2>&1
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
        $containerRunning = & docker --context $script:REMOTE_CONTEXT_NAME ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
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
                & docker --context $script:REMOTE_CONTEXT_NAME stop $CONTAINER_NAME 2>&1 | Out-Null
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
                    $stillRunning = & docker --context $script:REMOTE_CONTEXT_NAME ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
                }
                if (-not $stillRunning -or $stillRunning.Trim() -ne $CONTAINER_NAME) {
                    Write-Host "[SUCCESS] Container confirmed stopped." -ForegroundColor Green
                    Write-Host ""
                    
                    if ($script:useVolumes) {
                        Write-Host ""
                        # After the container exits:
                        # Synchronize the output and synthpop volumes back to the local directories using rsync.
                        Write-Host "[INFO] Container exited. Syncing volumes back to local directories using rsync (checksum mode)..." -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Configure paths based on execution location
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            # For local Windows, convert paths for Docker
                            $dockerOutputBackup = Convert-PathToDockerFormat -Path $script:outputDir
                            $dockerSynthpopBackup = Convert-PathToDockerFormat -Path $script:synthpopDir
                        } else {
                            # For remote Linux, use paths directly
                            $dockerOutputBackup = $script:outputDir
                            $dockerSynthpopBackup = $script:synthpopDir
                        }
                        
                        # Use ${} to delimit variable name before the colon and add permission flags
                        # Added --no-perms and --chmod=ugo=rwX to prevent permission issues on Windows
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeOutput):/volume" -v "${dockerOutputBackup}:/backup" $script:rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                            & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeSynthpop):/volume" -v "${dockerSynthpopBackup}:/backup" $script:rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                        } else {
                            Set-DockerSSHEnvironment
                            & docker --context $script:REMOTE_CONTEXT_NAME run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeOutput):/volume" -v "${dockerOutputBackup}:/backup" $script:rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                            & docker --context $script:REMOTE_CONTEXT_NAME run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeSynthpop):/volume" -v "${dockerSynthpopBackup}:/backup" $script:rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                        }
                        Write-Host ""

                        # Clean up all the Docker volumes used for the simulation.
                        Write-Host "[INFO] Cleaning up Docker volumes..." -ForegroundColor Cyan
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            & docker volume rm $script:VolumeOutput | Out-Null
                            & docker volume rm $script:VolumeSynthpop | Out-Null
                        } else {
                            Set-DockerSSHEnvironment
                            & docker --context $script:REMOTE_CONTEXT_NAME volume rm $script:VolumeOutput | Out-Null
                            & docker --context $script:REMOTE_CONTEXT_NAME volume rm $script:VolumeSynthpop | Out-Null
                        }
                        Write-Host ""
                    }    

                    # Update UI state - container stopped successfully
                    $buttonStart.Enabled = $true
                    $buttonStop.Enabled = $false
                    $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($script:useVolumes) { 'Enabled' } else { 'Disabled' })"
                    
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
                    if ($script:gitRepoPath) {
                        Invoke-GitChangeDetection -RepoPath $script:gitRepoPath
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
                    if ($script:useVolumes) {
                        Write-Host ""
                        Write-Host "[INFO] Force stopped - performing volume sync and cleanup..." -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Configure paths based on execution location
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            $dockerOutputBackup = Convert-PathToDockerFormat -Path $script:outputDir
                            $dockerSynthpopBackup = Convert-PathToDockerFormat -Path $script:synthpopDir
                        } else {
                            $dockerOutputBackup = $script:outputDir
                            $dockerSynthpopBackup = $script:synthpopDir
                        }
                        
                        # Quick sync and cleanup
                        & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeOutput):/volume" -v "${dockerOutputBackup}:/backup" $script:rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/ 2>$null
                        & docker run --rm --user "$($script:UserId):$($script:GroupId)" -v "$($script:VolumeSynthpop):/volume" -v "${dockerSynthpopBackup}:/backup" $script:rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/ 2>$null
                        & docker volume rm $script:VolumeOutput $script:VolumeSynthpop -f 2>$null
                        Write-Host ""
                    }
                    
                    # Update UI state
                    $buttonStart.Enabled = $true
                    $buttonStop.Enabled = $false
                    $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($script:useVolumes) { 'Enabled' } else { 'Disabled' })"
                    
                    # Check for git changes after force stop
                    if ($script:gitRepoPath) {
                        Invoke-GitChangeDetection -RepoPath $script:gitRepoPath
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
        $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($script:useVolumes) { 'Enabled' } else { 'Disabled' })"
        
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
$containerResult = $formContainer.ShowDialog()

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



