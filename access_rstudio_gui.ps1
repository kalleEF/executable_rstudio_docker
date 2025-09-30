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
    Size = New-Object System.Drawing.Size(450,200)
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

# Local Container button
$buttonLocal = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Local Container'
    Location = New-Object System.Drawing.Point(80,100)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formConnection.Controls.Add($buttonLocal)

# Remote Container button
$buttonRemote = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Remote Container'
    Location = New-Object System.Drawing.Point(250,100)
    Size = New-Object System.Drawing.Size(120,40)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
}
$formConnection.Controls.Add($buttonRemote)

# Add click handlers for the buttons
$buttonLocal.Add_Click({
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
        $sshTestResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'SSH connection successful'" 2>&1
        
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
                        $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_docker_$USERNAME.pub"
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
                                
                                $finalTest = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'Passwordless SSH successful'" 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    Write-Host ""
                                    Write-Host "  [SUCCESS] Passwordless SSH authentication confirmed!" -ForegroundColor Green
                                    Write-Host "  Response: $finalTest"
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

        $dockerTestResult = & ssh -o ConnectTimeout=10 $remoteHost "docker --version" 2>&1
        
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
        
        # Use the authenticated SSH connection
        Write-Host ""
        Write-Host "    Executing: ssh $remoteHost '$scanCommand'"
        Write-Host ""
        $availableFolders = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $scanCommand 2>&1
        
        if ($LASTEXITCODE -ne 0) {
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
        $gitCheckResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $gitCheckCommand 2>&1
        
        if ($gitCheckResult -match "Git repository found") {
            Write-Host ""
            Write-Host "    [SUCCESS] Git repository found in selected folder" -ForegroundColor Green
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "    [WARNING] No .git directory found in selected folder" -ForegroundColor Yellow
            Write-Host "    This folder may not be a Git repository"
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
        
        $dockerVersion = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker --version" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host ""
            Write-Host "    [SUCCESS] Docker is available on remote host" -ForegroundColor Green
            Write-Host "    Remote Docker version: $dockerVersion"
            Write-Host ""
            
            # Ensure Docker engine is running on remote host
            Write-Host ""
            Write-Host "    [INFO] Checking remote Docker engine status..." -ForegroundColor Cyan
            Write-Host ""
            & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker info" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
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
                    $dockerGroupCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "groups | grep -q docker && echo 'HAS_DOCKER_GROUP' || echo 'NO_DOCKER_GROUP'" 2>&1
                    
                    if ($dockerGroupCheck -match "HAS_DOCKER_GROUP") {
                        Write-Host ""
                        Write-Host "    [INFO] User is in docker group, trying Docker without sudo..." -ForegroundColor Cyan
                        Write-Host ""
                        # Try starting Docker service as regular user (if systemd allows)
                        $startResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "systemctl --user start docker || echo 'USER_START_FAILED'" 2>&1
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
                        $sudoCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "sudo -n systemctl status docker >/dev/null 2>&1 && echo 'SUDO_OK' || echo 'SUDO_NEEDS_PASSWORD'" 2>&1
                        
                        if ($sudoCheck -match "SUDO_OK") {
                            Write-Host ""
                            Write-Host "    [SUCCESS] Passwordless sudo available for Docker service" -ForegroundColor Green
                            Write-Host ""
                            $startResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "sudo systemctl start docker" 2>&1
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
                        
                        & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker info" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host " [SUCCESS]" -ForegroundColor Green
                            break
                        } else {
                            Write-Host ""
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
                    
                    # Final check
                    & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker info" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
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

    # Check if the context already exists
    Write-Host "    [INFO] Checking for existing Docker context..." -ForegroundColor Cyan
    $existing = & docker context ls --format '{{.Name}}' 2>$null
    $exists = $existing -contains $RemoteContextName

    if (-not $exists) {
        Write-Host "    [INFO] Creating Docker context '$RemoteContextName' for ssh://$remoteHost..." -ForegroundColor Cyan
        & docker context create $RemoteContextName `
            --description "Remote Docker engine over SSH (Ubuntu 24.04)" `
            --docker "host=ssh://$remoteHost"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker context created successfully" -ForegroundColor Green
        } else {
            Write-Host "    [ERROR] Failed to create Docker context" -ForegroundColor Red
        }
    } else {
        Write-Host "    [INFO] Context '$RemoteContextName' already exists" -ForegroundColor Cyan
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
    Write-Host "    [INFO] Testing remote Docker connection..." -ForegroundColor Cyan
    & docker --context $RemoteContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Remote Docker connection test passed" -ForegroundColor Green
    } else {
        Write-Host "    [WARNING] Remote Docker connection test failed" -ForegroundColor Yellow
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
            & docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
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
                        
                        & docker info 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host " [SUCCESS]" -ForegroundColor Green
                            break
                        } else {
                            Write-Host ""
                        }
                        
                        # Show different messages at different intervals
                        if ($attempt -eq 10) {
                            Write-Host "    [INFO] Docker is still starting up (this may take a moment)..." -ForegroundColor Cyan
                        } elseif ($attempt -eq 20) {
                            Write-Host "    [INFO] Still waiting for Docker daemon (almost ready)..." -ForegroundColor Cyan
                        }
                        
                    } while ($attempt -lt $maxAttempts)
                    
                    # Final check
                    & docker info 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
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
                            [System.Windows.Forms.MessageBox]::Show("Please start Docker Desktop manually and wait for it to be ready, then click OK to continue.", "Manual Start Required", "OK", "Information")
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

# 1: Helper function to extract and construct potential paths from the YAML file
function Get-YamlPathValue {
    param (
        [string]$YamlPath,
        [string]$Key,
        [string]$BaseDir # Pass ProjectRoot here (already uses forward slashes)
    )
    $line = Select-String -Path $YamlPath -Pattern "^$Key\s*:" | Select-Object -First 1
    if ($line) {
        $value = ($line.Line -split ":\s*", 2)[1].Split("#")[0].Trim()
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
    # Get all containers (running and stopped) that contain the username
    $existingContainers = & docker ps -a --filter "name=_$USERNAME" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>$null
    
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
            $runningContainers = & docker ps --filter "name=_$USERNAME" --format "{{.Names}}" 2>$null
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
                    
                    foreach ($runningContainer in $runningList) {
                        if ($runningContainer.Trim() -ne "") {
                            Write-Host "  Stopping container: $runningContainer"
                            & docker stop $runningContainer 2>$null
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
    $runningCheck = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
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

# Event handlers
$buttonStart.Add_Click({
    Write-Host ""
    Write-Host "[INFO] Container is starting up..." -ForegroundColor Cyan
    Write-Host "  Container: $CONTAINER_NAME"
    
    # Get options from form
    $useVolumes = $checkBoxVolumes.Checked
    $portOverride = $textBoxPort.Text.Trim()
    $customParams = $textBoxParams.Text.Trim()
    $SimDesignYAML = $textBoxSimDesign.Text.Trim()
    
    Write-Host "  Advanced Options:"
    Write-Host "    Use Volumes: $useVolumes"
    Write-Host "    Port Override: $(if($portOverride) { $portOverride } else { 'Default' })"
    Write-Host "    Custom Parameters: $(if($customParams) { $customParams } else { 'None' })"
    Write-Host "    sim_design.yaml file: $(if($SimDesignYAML) { $SimDesignYAML } else { 'Default' })"
    Write-Host ""

    # Resolve docker setup directory based on current model
    if (-not $script:LOCAL_REPO_PATH -and -not $script:REMOTE_REPO_PATH) {
        Write-Host "[FATAL ERROR] No path for repository or model found. Please restart the application and select a folder."
        Exit 1
    } elseif (Test-Path $script:LOCAL_REPO_PATH) {
        $ScriptDir = "$script:LOCAL_REPO_PATH\docker_setup"
        Write-Host "[INFO] Using local repository path: $script:LOCAL_REPO_PATH" -ForegroundColor Cyan
    } elseif (Test-Path $script:REMOTE_REPO_PATH) {
        $ScriptDir = "$script:REMOTE_REPO_PATH/docker_setup"
        Write-Host "[INFO] Using remote repository path: $script:REMOTE_REPO_PATH" -ForegroundColor Cyan
    } else {
        Write-Host "[FATAL ERROR] Neither local nor remote repository paths are valid. Please restart the application and select a valid folder."
        Exit 1
    }
    # Validate that the docker_setup directory exists (THIS IS MANDATORY)
    if (-not (Test-Path $ScriptDir)) {
        Write-Host "[FATAL ERROR] Your repository has no Docker setup directory at '$ScriptDir'"
        Exit 1
    }

    # Resolve project root directory (one level above the current script directory)
    $ProjectRoot = $script:LOCAL_REPO_PATH

    # If SimDesignYaml is a relative path, resolve it relative to the project root
    if (-not [System.IO.Path]::IsPathRooted($SimDesignYaml)) {
        # Normalize path separators to forward slashes for cross-platform compatibility
        $SimDesignYamlNormalized = $SimDesignYaml -replace '\\', '/'
        $TempPath = "$ProjectRoot/$SimDesignYamlNormalized" -replace '/+', '/'
        # Resolve the path to handle .. components properly
        $SimDesignYaml = (Resolve-Path $TempPath -ErrorAction SilentlyContinue).Path
        if (-not $SimDesignYaml) {
            # If Resolve-Path fails, try manual construction (for the actual inputs directory)
            if ($SimDesignYamlNormalized -eq "../inputs/sim_design.yaml") {
                $SimDesignYaml = "$ProjectRoot/inputs/sim_design.yaml"
            } else {
                $SimDesignYaml = $TempPath
            }
        }
    }

    # Validate that the YAML file exists
    if (-not (Test-Path $SimDesignYaml)) {
        Write-Host "[FATAL ERROR] YAML file not found at '$SimDesignYaml'"
        Write-Host "Original path provided: '..\inputs\sim_design.yaml'"
        Write-Host "Project root: '$ProjectRoot'"
        Exit 1
    }

    Write-Host "[INFO] Using configuration file: $SimDesignYaml" -ForegroundColor Cyan
    Write-Host ""

    # Check if Docker image for the current model already exists
    $DockerImageName = $script:SELECTED_REPO.ToLower()
    Write-Host "[INFO] Checking if a Docker image for your repo (e.g. $DockerImageName) already exists..." -ForegroundColor Cyan
    Write-Host ""

    # Check if image exists
    $imageExists = $false
    try {
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            # Check locally
            $imageCheck = & docker images --format "{{.Repository}}" | Where-Object { $_ -eq $DockerImageName }
            $imageExists = $null -ne $imageCheck
        } else {
            # Check on remote host
            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
            $imageCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker images --format '{{.Repository}}' | grep -q '^$DockerImageName$' && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1
            $imageExists = $imageCheck -match "EXISTS"
        }
    } catch {
        Write-Host "[WARNING] Could not check for existing Docker image: $($_.Exception.Message)" -ForegroundColor Yellow
        $imageExists = $false
    }

    if ($imageExists) {
        Write-Host "[SUCCESS] Docker image '$DockerImageName' that can be used for your container already exists" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "[INFO] Docker image '$DockerImageName' does not exist, building from Dockerfile..." -ForegroundColor Cyan
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
                $dockerfileCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "test -f '$dockerfilePath' && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1
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
                Write-Host "[DEBUG] Docker command: $dockerCommand"
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
                    # Execute SSH command directly and show output in real-time
                    $sshCommand = "ssh -o ConnectTimeout=30 -o BatchMode=yes $remoteHost `"$buildCommand`""
                    Write-Host "[DEBUG] SSH command: $sshCommand"
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
                        $prereqDockerfileCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "test -f '$prereqDockerfilePath' && echo 'EXISTS' || echo 'NOT_EXISTS'" 2>&1
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
                            Write-Host "[DEBUG] Prerequisite command: $prereqCommand"
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
                                # Execute SSH prerequisite command directly and show output in real-time
                                $prereqSSHCommand = "ssh -o ConnectTimeout=30 -o BatchMode=yes $remoteHost `"$prereqBuildCommand`""
                                Write-Host "[DEBUG] SSH prerequisite command: $prereqSSHCommand"

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
                                    Write-Host "[DEBUG] Retry command: $retryCommand"
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
                                        # Execute SSH retry command directly and show output in real-time
                                        $retrySSHCommand = "ssh -o ConnectTimeout=30 -o BatchMode=yes $remoteHost `"$retryBuildCommand`""
                                        Write-Host ""
                                        Write-Host "[DEBUG] SSH retry command: $retrySSHCommand"

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
    $UserId = 1000 #TODO: Check SSH user implementation to avoid root access? See ChatGPT suggestions.
    $GroupId = 1000

    # Define user-specific Docker volume names using sanitized username (only for output and synthpop)
    $VolumeOutput    = "impactncd_germany_output_$SafeCurrentUser"
    $VolumeSynthpop  = "impactncd_germany_synthpop_$SafeCurrentUser"

    # TODO: Logic for synthpop and output folders on local and remote POTENTIAL IMPLICATIONS FOR USER CREATION ETC!    
    # Replace backwards with forward slashes in ProjectRoot for Docker compatibility
    $ProjectRoot = $ProjectRoot -replace '\\', '/'

    # Call the function passing $ProjectRoot
    Write-Host ""
    Write-Host ""
    $outputDir    = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "output_dir" -BaseDir $ProjectRoot
    Write-Host ""
    Write-Host ""
    $synthpopDir  = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "synthpop_dir" -BaseDir $ProjectRoot
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
        $rsyncImage = "rsync-alpine"
        & docker image inspect $rsyncImage > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[INFO] Building rsync-alpine image..." -ForegroundColor Cyan

            # Check if Dockerfile.rsync exists
            $DockerfileRsync = Join-Path $ScriptDir "Dockerfile.rsync"
            if (Test-Path $DockerfileRsync) {
                Write-Host "[INFO] Using Dockerfile.rsync..." -ForegroundColor Cyan
                & docker build -f "$DockerfileRsync" -t $rsyncImage $ScriptDir
            } else {
                Write-Host "[WARNING] Dockerfile.rsync not found, creating rsync image inline..." -ForegroundColor Yellow
                $InlineDockerfile = @"
FROM alpine:latest
RUN apk add --no-cache rsync
"@
                $InlineDockerfile | & docker build -t $rsyncImage -
            }
        } else {
            Write-Host "[INFO] Using existing rsync-alpine image." -ForegroundColor Cyan
        }

        # Ensure local output directories exist
        if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
        if (-not (Test-Path $synthpopDir)) { New-Item -ItemType Directory -Path $synthpopDir | Out-Null }

        # Remove any existing volumes (ignore errors if not removable)
        Write-Host "[INFO] Removing any existing volumes (if possible)..." -ForegroundColor Cyan
        & docker volume rm $VolumeOutput -f 2>$null
        & docker volume rm $VolumeSynthpop -f 2>$null

        # Create fresh Docker-managed volumes
        & docker volume create $VolumeOutput | Out-Null
        & docker volume create $VolumeSynthpop | Out-Null

        # Fix volume ownership and pre-populate volumes:
        # Docker volumes are created with root ownership by default. We need to fix
        # the ownership before we can populate them as the calling user.
        Write-Host "[INFO] Setting correct ownership for Docker volumes..." -ForegroundColor Cyan
        & docker run --rm -v "${VolumeOutput}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
        & docker run --rm -v "${VolumeSynthpop}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
        Write-Host ""

        # Pre-populate volumes:
        # The output and synthpop volumes are populated from the respective local folders.
        Write-Host "[INFO] Populating output volume from local folder..." -ForegroundColor Cyan
        # Use permission-tolerant copy with fallback logic
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            # For local Windows, convert paths for Docker
            $dockerOutputSource = Convert-PathToDockerFormat -Path $outputDir
            $dockerSynthpopSource = Convert-PathToDockerFormat -Path $synthpopDir
        } else {
            # For remote Linux, use paths directly
            $dockerOutputSource = $outputDir
            $dockerSynthpopSource = $synthpopDir
        }

        Write-Host "[INFO] Populating output volume from local folder..." -ForegroundColor Cyan
        Write-Host ""
        & docker run --rm --user "${UserId}:${GroupId}" -v "${dockerOutputSource}:/source" -v "${VolumeOutput}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
        Write-Host "[INFO] Populating synthpop volume from local folder..." -ForegroundColor Cyan
        Write-Host ""
        & docker run --rm --user "${UserId}:${GroupId}" -v "${dockerSynthpopSource}:/source" -v "${VolumeSynthpop}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"

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
            # Port mapping with override support
            "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
            # Directory mounts
            "-v", "${VolumeOutput}:/home/rstudio/IMPACTncd_Germany/outputs",
            "-v", "${VolumeSynthpop}:/home/rstudio/IMPACTncd_Germany/inputs/synthpop",
            # SSH key and known_hosts for git access (Windows paths)
            "-v", "${sshKeyPath}:/keys/id_ed25519_${USERNAME}:ro",
            "-v", "${knownHostsPath}:/etc/ssh/ssh_known_hosts:ro",
            # Working directory
            "--workdir", "/home/rstudio/IMPACTncd_Germany"
        )

        # Add final argument
        $dockerArgs += $DockerImageName

        # Execute docker with the arguments array
        Write-Host "[INFO] Starting RStudio Server container with volumes..." -ForegroundColor Cyan
        & docker $dockerArgs
        Write-Host ""
        Write-Host ""
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[SUCCESS] RStudio Server container started successfully!" -ForegroundColor Green
            Write-Host ""
            
            # Wait a moment for the container to fully start
            Write-Host "[INFO] Waiting for RStudio Server to initialize..." -ForegroundColor Cyan
            Start-Sleep -Seconds 3
            
            # Check if container is still running
            $containerStatus = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
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
                $containerLogs = & docker logs $CONTAINER_NAME 2>&1
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
                # Port mapping with override support
                "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
                # Directory mounts
                "--mount", "type=bind,source=$DockerOutputDir,target=/home/rstudio/IMPACTncd_Germany/outputs",
                "--mount", "type=bind,source=$DockerSynthpopDir,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop",
                # SSH key and known_hosts for git access (Windows paths)
                "-v", "${sshKeyPath}:/keys/id_ed25519_${USERNAME}:ro",
                "-v", "${knownHostsPath}:/etc/ssh/ssh_known_hosts:ro",
                # Working directory
                "--workdir", "/home/rstudio/IMPACTncd_Germany"
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
                # Port mapping with override support
                "-p", "$(if($portOverride) { $portOverride } else { '8787' }):8787",
                # Directory mounts (Unix paths)
                "--mount", "type=bind,source=$DockerOutputDir,target=/home/rstudio/IMPACTncd_Germany/outputs",
                "--mount", "type=bind,source=$DockerSynthpopDir,target=/home/rstudio/IMPACTncd_Germany/inputs/synthpop",
                # SSH key and known_hosts for git access (Linux paths)
                "-v", "${sshKeyPath}:/keys/id_ed25519_${USERNAME}:ro",
                "-v", "${knownHostsPath}:/etc/ssh/ssh_known_hosts:ro",
                # Working directory
                "--workdir", "/home/rstudio/IMPACTncd_Germany"
            )
        }

        # Add final argument (Docker image name)
        $dockerArgs += $DockerImageName

        # Execute docker with the arguments array
        Write-Host ""
        Write-Host "[INFO] Starting RStudio Server container..." -ForegroundColor Cyan
        Write-Host ""
        & docker $dockerArgs
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
            $containerStatus = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Status}}" 2>$null
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
                $containerLogs = & docker logs $CONTAINER_NAME 2>&1
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
    $containerRunning = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
    Write-Host ""
    
    if ($containerRunning -and $containerRunning.Trim() -eq $CONTAINER_NAME) {
        Write-Host "[INFO] Container '$CONTAINER_NAME' is running. Stopping..." -ForegroundColor Cyan
        Write-Host ""
        
        try {
            # Stop the container gracefully
            Write-Host "[INFO] Attempting graceful shutdown (SIGTERM)..." -ForegroundColor Cyan
            Write-Host ""
            & docker stop $CONTAINER_NAME 2>&1 | Out-Null
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[SUCCESS] Container '$CONTAINER_NAME' stopped successfully" -ForegroundColor Green
                Write-Host ""
                
                # Wait a moment to ensure container is fully stopped
                Start-Sleep -Seconds 2
                
                # Verify the container is actually stopped
                $stillRunning = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
                if (-not $stillRunning -or $stillRunning.Trim() -ne $CONTAINER_NAME) {
                    Write-Host "[SUCCESS] Container confirmed stopped." -ForegroundColor Green
                    Write-Host ""
                    
                    if ($useVolumes) {
                        Write-Host ""
                        # After the container exits:
                        # Synchronize the output and synthpop volumes back to the local directories using rsync.
                        Write-Host "[INFO] Container exited. Syncing volumes back to local directories using rsync (checksum mode)..." -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Configure paths based on execution location
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            # For local Windows, convert paths for Docker
                            $dockerOutputBackup = Convert-PathToDockerFormat -Path $outputDir
                            $dockerSynthpopBackup = Convert-PathToDockerFormat -Path $synthpopDir
                        } else {
                            # For remote Linux, use paths directly
                            $dockerOutputBackup = $outputDir
                            $dockerSynthpopBackup = $synthpopDir
                        }
                        
                        # Use ${} to delimit variable name before the colon and add permission flags
                        # Added --no-perms and --chmod=ugo=rwX to prevent permission issues on Windows
                        & docker run --rm --user "${UserId}:${GroupId}" -v "${VolumeOutput}:/volume" -v "${dockerOutputBackup}:/backup" $rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                        & docker run --rm --user "${UserId}:${GroupId}" -v "${VolumeSynthpop}:/volume" -v "${dockerSynthpopBackup}:/backup" $rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
                        Write-Host ""

                        # Clean up all the Docker volumes used for the simulation.
                        Write-Host "[INFO] Cleaning up Docker volumes..." -ForegroundColor Cyan
                        & docker volume rm $VolumeOutput | Out-Null
                        & docker volume rm $VolumeSynthpop | Out-Null
                        Write-Host ""
                    }    

                    # Update UI state - container stopped successfully
                    $buttonStart.Enabled = $true
                    $buttonStop.Enabled = $false
                    $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($useVolumes) { 'Enabled' } else { 'Disabled' })"
                    
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
                    if ($useVolumes) {
                        Write-Host ""
                        Write-Host "[INFO] Force stopped - performing volume sync and cleanup..." -ForegroundColor Cyan
                        Write-Host ""
                        
                        # Configure paths based on execution location
                        if ($CONTAINER_LOCATION -eq "LOCAL") {
                            $dockerOutputBackup = Convert-PathToDockerFormat -Path $outputDir
                            $dockerSynthpopBackup = Convert-PathToDockerFormat -Path $synthpopDir
                        } else {
                            $dockerOutputBackup = $outputDir
                            $dockerSynthpopBackup = $synthpopDir
                        }
                        
                        # Quick sync and cleanup
                        & docker run --rm --user "${UserId}:${GroupId}" -v "${VolumeOutput}:/volume" -v "${dockerOutputBackup}:/backup" $rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/ 2>$null
                        & docker run --rm --user "${UserId}:${GroupId}" -v "${VolumeSynthpop}:/volume" -v "${dockerSynthpopBackup}:/backup" $rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/ 2>$null
                        & docker volume rm $VolumeOutput $VolumeSynthpop -f 2>$null
                        Write-Host ""
                    }
                    
                    # Update UI state
                    $buttonStart.Enabled = $true
                    $buttonStop.Enabled = $false
                    $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($useVolumes) { 'Enabled' } else { 'Disabled' })"
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
        $labelInstruction.Text = "Container: $CONTAINER_NAME`n`nRepository: $($script:SELECTED_REPO)`nUser: $USERNAME`n`nStatus: STOPPED`nLocation: $CONTAINER_LOCATION`nVolumes: $(if($useVolumes) { 'Enabled' } else { 'Disabled' })"
        
        Write-Host "[INFO] UI updated to reflect stopped state" -ForegroundColor Cyan
        Write-Host ""
    }
})

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

#-----------------------------------------------------------------------#
#   STEP 5.1: IF REMOTE - LOGIC FOR MOUNTING FOLDERS AND COPY SSH KEY   #
#-----------------------------------------------------------------------#

<# 
Logic:
    1. Collect everything that needs to be mounted locally
    2. This includes the GitHub SSH key that is needed to clone/pull/push from inside RStudio
    3. Save all mounts into a dockerargs variable
    4. Integrate into Chris code including the UseVolumes option
#>

#----------------------------------------------------------------------#
#   STEP 5.2: IF LOCAL - LOGIC FOR MOUNTING FOLDERS AND COPY SSH KEY   #
#----------------------------------------------------------------------#

<# 
Logic:
    1. Collect everything that needs to be mounted locally
    2. This includes the GitHub SSH key that is needed to clone/pull/push from inside RStudio
    3. Optional: Enable users to mount additional local folders if needed
    4. Save all mounts into a dockerargs variable
    5. Integrate into Chris code including the UseVolumes option
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



