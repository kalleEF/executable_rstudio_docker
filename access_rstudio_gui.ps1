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
            Write-Host "Please restart this application as Administrator."
            [System.Windows.Forms.MessageBox]::Show("This application requires Administrator privileges to manage Docker containers.`n`nPlease right-click and select 'Run as Administrator'.", "Administrator Required", "OK", "Warning")
            exit 1
        }
    } catch {
        Write-Host "Could not automatically elevate privileges."
        Write-Host "Please manually restart this application as Administrator."
        [System.Windows.Forms.MessageBox]::Show("This application requires Administrator privileges to manage Docker containers.`n`nPlease right-click and select 'Run as Administrator'.", "Administrator Required", "OK", "Warning")
        exit 1
    }
} else {
    Write-Host ""
    Write-Host "[SUCCESS] Running with Administrator privileges"
    Write-Host ""
}

#--------------------------------------#
#   STEP 0: SETUP AND PRE-REQUISITES   #
#--------------------------------------#

# Ensure Windows Forms app environment
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

#----------------------------------------------#
#   STEP 1: PROMPT FOR USERNAME AND PASSWORD   #
#----------------------------------------------#

Write-Host "                                                         ,----,                
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
        Write-Host "ERROR: No username provided"
        $textUser.Focus()
        return
    }
    
    # Validate password
    if ([string]::IsNullOrWhiteSpace($textPass.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a password.', 'Error', 'OK', 'Error')
        Write-Host "ERROR: No password provided"
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
        Write-Host "[ERROR] Username became empty after normalization"
        [System.Windows.Forms.MessageBox]::Show('Username cannot be empty after removing spaces.', 'Invalid Username', 'OK', 'Error')
        exit 1
    }
    
    Write-Host ""
    Write-Host "[SUCCESS] Credentials collected successfully"
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
    Write-Host "[ERROR] User cancelled the dialog - no credentials provided"
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
        Write-Host "[INFO] SSH key already exists"
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

        Write-Host "[INFO] Generating new SSH key for Docker operations..."
        Write-Host ""
        
        # Ensure .ssh directory exists
        $sshDir = "$HOME\.ssh"
        if (-not (Test-Path $sshDir)) {
            New-Item -Path $sshDir -ItemType Directory -Force | Out-Null
            Write-Host "  Created .ssh directory"
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
            Write-Host "  [ERROR] ssh-keygen execution failed: $($_.Exception.Message)"
            $keyGenResult = 1
        }
        
        # Check if SSH key generation was successful
        if ($keyGenResult -eq 0 -and (Test-Path "$HOME\.ssh\id_ed25519_$USERNAME.pub")) {
            Write-Host ""
            Write-Host "[SUCCESS] New SSH key generated successfully!"
            Write-Host "  Private key: $HOME\.ssh\id_ed25519_$USERNAME"
            Write-Host "  Public key: $HOME\.ssh\id_ed25519_$USERNAME.pub"
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "[ERROR] Failed to generate new SSH key!"
            Write-Host "  Exit code: $keyGenResult"
            Write-Host "  Expected public key at: $HOME\.ssh\id_ed25519_$USERNAME.pub"
            Write-Host ""
            exit 1
        }
        
        if (Test-Path $sshPublicKeyPath) {
            Write-Host ""
            Write-Host "[SUCCESS] Failsafe check: SSH key generated successfully!"
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "[ERROR] Failed to generate SSH key!"
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
            $publicKey | Set-Clipboard
            Write-Host "[SUCCESS] Public key copied to clipboard!"
        } catch {
            Write-Host "[WARNING] Could not copy to clipboard, but key will be displayed."
        }

        # Show the initial message box
        [System.Windows.Forms.MessageBox]::Show($message, 'SSH Key Setup', 'OK', 'Information')

        # Create a separate dialog with selectable text for the SSH key
        $formKeyDisplay = New-Object System.Windows.Forms.Form -Property @{ 
            Text = 'SSH Public Key - Copy to GitHub'
            Size = New-Object System.Drawing.Size(700,400)
            StartPosition = 'CenterScreen'
            FormBorderStyle = 'Sizable'
            MaximizeBox = $true
            MinimizeBox = $false
        }

        # Instruction label
        $labelKeyInstruction = New-Object System.Windows.Forms.Label -Property @{ 
            Text = "Copy this SSH public key to GitHub (Settings -> SSH and GPG keys -> New SSH key):"
            Location = New-Object System.Drawing.Point(10,10)
            Size = New-Object System.Drawing.Size(670,30)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
        }
        $formKeyDisplay.Controls.Add($labelKeyInstruction)

        # Text box with the SSH key (selectable and copyable)
        $textBoxKey = New-Object System.Windows.Forms.TextBox -Property @{ 
            Location = New-Object System.Drawing.Point(10,50)
            Size = New-Object System.Drawing.Size(670,250)
            Multiline = $true
            ScrollBars = 'Vertical'
            ReadOnly = $true
            Font = New-Object System.Drawing.Font("Consolas", 9, [System.Drawing.FontStyle]::Regular)
            Text = $publicKey
            WordWrap = $false
        }
        $formKeyDisplay.Controls.Add($textBoxKey)

        # Select all text by default for easy copying
        $textBoxKey.SelectAll()
        $textBoxKey.Focus()

        # Copy button
        $buttonCopyKey = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Copy to Clipboard'
            Location = New-Object System.Drawing.Point(10,320)
            Size = New-Object System.Drawing.Size(120,30)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
        }
        $formKeyDisplay.Controls.Add($buttonCopyKey)

        $buttonCopyKey.Add_Click({
            try {
                $publicKey | Set-Clipboard
                [System.Windows.Forms.MessageBox]::Show('SSH key copied to clipboard!', 'Copy Success', 'OK', 'Information')
            } catch {
                [System.Windows.Forms.MessageBox]::Show('Failed to copy to clipboard. Please select and copy manually.', 'Copy Failed', 'OK', 'Warning')
            }
        })

        # Close button
        $buttonCloseKey = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Close'
            Location = New-Object System.Drawing.Point(140,320)
            Size = New-Object System.Drawing.Size(75,30)
            Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Bold)
        }
        $formKeyDisplay.Controls.Add($buttonCloseKey)

        $buttonCloseKey.Add_Click({
            $formKeyDisplay.Close()
        })

        # Show the key display dialog
        $formKeyDisplay.ShowDialog() | Out-Null

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
        Write-Host "[INFO] Configuring SSH agent..."
        
        # Start ssh-agent service if not running
        $sshAgentService = Get-Service ssh-agent -ErrorAction SilentlyContinue
        if ($sshAgentService.Status -ne 'Running') {
            Set-Service ssh-agent -StartupType Automatic
            Start-Service ssh-agent
            Write-Host "  SSH agent service started"
        }
        
        # Add key to ssh-agent
        ssh-add $sshKeyPath
        Write-Host "  SSH key added to agent"
        Write-Host ""
        
    } catch {
        Write-Host "[WARNING] Could not configure SSH agent. Key may still work for GitHub."
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
    Write-Host "[INFO] Testing SSH connection to remote workstation..."
    
    # Define remote host (update this IP address to match your workstation)
    $remoteHost = "php-workstation@10.162.192.90"  #TODO: Implement individual users!
 
    # Test SSH connection with detailed feedback
    try {
        Write-Host "  Attempting connection to: $remoteHost"
        Write-Host ""
        
        # First, try SSH key authentication (no password needed)
        Write-Host "  [INFO] Testing SSH key authentication..."
        $sshTestResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'SSH connection successful'" 2>&1
        
        $SSHEXITCODE = $LASTEXITCODE

        if ($SSHEXITCODE -eq 0) {
            Write-Host "  [SUCCESS] SSH key authentication successful!"
            Write-Host "  Response: $sshTestResult"
            Write-Host "  Remote workstation is reachable"
            Write-Host ""

            # Extract IP address from remote host string
            $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
            $script:REMOTE_HOST_IP = $remoteIP
            
        } else {
            Write-Host "  [INFO] SSH key authentication failed - password authentication required"
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
                Write-Host "  [INFO] Password provided, securing credentials..."
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
                
                Write-Host "  [INFO] Credentials secured, testing connection..."
                Write-Host ""
                
                # Test connection with password using a more reliable method
                try {
                    Write-Host "  [INFO] Testing SSH connection with password..."
                    
                    # Method 1: Try using plink (PuTTY's command line tool) if available
                    $plinkPath = Get-Command plink.exe -ErrorAction SilentlyContinue
                    if ($plinkPath) {
                        Write-Host "  Using PuTTY plink for password authentication..."
                        
                        # Username and host already extracted during credential creation
                        # Convert secure password to plain text only when needed for plink
                        $plainPassword = $remoteCredential.GetNetworkCredential().Password
                        
                        # Test connection with plink
                        $plinkResult = & plink.exe -ssh -batch -pw $plainPassword -l $sshUser $sshHost "echo SSH_SUCCESS" 2>&1
                        
                        # Clear the plain text password from memory immediately
                        $plainPassword = $null
                        [System.GC]::Collect()
                        
                        if ($plinkResult -match "SSH_SUCCESS") {
                            Write-Host "  [SUCCESS] Password authentication successful!"
                            Write-Host ""
                            $authSuccess = $true
                        } else {
                            Write-Host "  [ERROR] Password authentication failed with plink"
                            Write-Host "  Output: $plinkResult"
                            $authSuccess = $false
                        }
                        
                    } else {
                        # Method 2: Use expect-like functionality with PowerShell and SSH
                        Write-Host "  Using PowerShell SSH automation (plink not found)..."
                        
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
                            Write-Host "  [SUCCESS] Password authentication successful!"
                            Write-Host ""
                            $authSuccess = $true
                        } else {
                            # Method 3: Try with sshpass if available (Windows Subsystem for Linux)
                            $sshpassTest = Get-Command sshpass -ErrorAction SilentlyContinue
                            if ($sshpassTest) {
                                Write-Host "  Trying with sshpass..."
                                
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
                                    Write-Host "  [SUCCESS] Password authentication successful with sshpass!"
                                    Write-Host ""
                                    $authSuccess = $true
                                } else {
                                    $authSuccess = $false
                                }
                            } else {
                                Write-Host "  [ERROR] Could not authenticate with available methods"
                                Write-Host "  Output: $batchResult"
                                $authSuccess = $false
                            }
                        }
                    }
                    
                    if ($authSuccess) {
                        # Now copy the SSH key for future passwordless authentication
                        Write-Host "  [INFO] Setting up SSH key for passwordless authentication..."
                        Write-Host "  This will allow future connections without password prompts"
                        Write-Host ""
                        
                        # Get the public key content
                        $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_docker_$USERNAME.pub"
                        if (Test-Path $sshPublicKeyPath) {
                            $publicKeyContent = Get-Content $sshPublicKeyPath -Raw
                            $publicKeyContent = $publicKeyContent.Trim()
                            
                            Write-Host "  Copying SSH key to remote host..."
                            
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
                                Write-Host "  [SUCCESS] SSH key successfully copied to remote host!"
                                Write-Host "  Future connections will not require password"
                                Write-Host ""
                                
                                # Test passwordless connection
                                Write-Host "  [INFO] Testing passwordless SSH connection..."
                                Start-Sleep -Seconds 2  # Give the remote system a moment to process the key
                                
                                $finalTest = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'Passwordless SSH successful'" 2>&1
                                if ($LASTEXITCODE -eq 0) {
                                    Write-Host "  [SUCCESS] Passwordless SSH authentication confirmed!"
                                    Write-Host "  Response: $finalTest"
                                } else {
                                    Write-Host "  [INFO] Passwordless test not yet working, but key was copied"
                                    Write-Host "  This may take a moment to take effect on the remote system"
                                }
                            } else {
                                Write-Host "  [WARNING] Failed to copy SSH key to remote host"
                                Write-Host "  Password authentication will be required for future connections"
                                Write-Host "  Details: $keyCopyResult"
                            }
                        } else {
                            Write-Host "  [ERROR] SSH public key not found at: $sshPublicKeyPath"
                            Write-Host "  Cannot set up passwordless authentication"
                        }
                        
                        # Extract IP address and continue
                        $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                        $script:REMOTE_HOST_IP = $remoteIP
                        
                        # Secure cleanup: Clear the credential object from memory
                        $remoteCredential = $null
                        $securePassword = $null
                        [System.GC]::Collect()
                        Write-Host "  [INFO] Credentials securely cleared from memory"
                        
                    } else {
                        # Secure cleanup: Clear the credential object from memory even on failure
                        $remoteCredential = $null
                        $securePassword = $null
                        [System.GC]::Collect()
                        
                        Write-Host "  [ERROR] All password authentication methods failed"
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
                    
                    Write-Host "  [ERROR] Failed to test password authentication"
                    Write-Host "  Details: $($_.Exception.Message)"
                    Write-Host ""
                    [System.Windows.Forms.MessageBox]::Show("Failed to test password authentication.`n`nError: $($_.Exception.Message)", "Connection Error", "OK", "Error")
                    return
                }
                
            } else {
                Write-Host "  [INFO] User cancelled password authentication"
                Write-Host ""
                # No credentials to clean up since user cancelled
                return
            }
        }

    } catch {
        Write-Host ""
        Write-Host "[ERROR] Unexpected error during SSH connection test"
        Write-Host "  Details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Unexpected error during remote connection test.`n`nError: $($_.Exception.Message)", "Connection Error", "OK", "Error")
        return
    }
    
    try {
        if ($SSHEXITCODE -eq 0){
        
        Write-Host "[INFO] Testing Docker availability on remote host..."

        $dockerTestResult = & ssh -o ConnectTimeout=10 $remoteHost "docker --version" 2>&1

        Write-Host "[SUCCESS] Docker is available on remote host"
        Write-Host "  Version: $dockerTestResult"
        Write-Host ""
        }
    } catch {
        Write-Host ""
        Write-Host "[ERROR] Docker unavailable on remote host"
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
    Write-Host "[SUCCESS] Container location configured"
    Write-Host "  Location: LOCAL"
    Write-Host "  Mode: Local Docker containers"
    Write-Host ""
    Write-Host "==================================="
    Write-Host ""
} elseif ($connectionResult -eq [System.Windows.Forms.DialogResult]::No -and $script:REMOTE_HOST_IP) {
    $CONTAINER_LOCATION = "REMOTE@$($script:REMOTE_HOST_IP)"
    Write-Host "[SUCCESS] Container location configured"
    Write-Host "  Location: REMOTE"
    Write-Host "  Target: $($script:REMOTE_HOST_IP)"
    Write-Host "  Mode: Remote Docker containers via SSH"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "[ERROR] Configuration failed"
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
    
    Write-Host "    [INFO] Scanning remote host for available repositories..."
    
    # Define the base path on remote host where repositories are stored
    $remoteRepoPath = "/home/php-workstation/Schreibtisch/IMPACT/Models"
    #$remoteHost = "php_workstation@$($script:REMOTE_HOST_IP)" TODO: CHECK IF NEEDED
    
    try {
        # Scan for subdirectories on remote host
        Write-Host "    Scanning directory: $remoteRepoPath"
        Write-Host "    Using remote host: $remoteHost"
        Write-Host ""
        
        # Ensure we're using the correct remote host (the one we authenticated with)
        if ([string]::IsNullOrEmpty($remoteHost)) {
            # Reconstruct the remote host from the IP we stored earlier
            if ($script:REMOTE_HOST_IP) {
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                Write-Host "    [INFO] Reconstructed remote host: $remoteHost"
            } else {
                Write-Host "    [ERROR] No remote host information available"
                throw "Remote host configuration is missing"
            }
        }
        
        $scanCommand = "find '$remoteRepoPath' -maxdepth 1 -type d -not -path '$remoteRepoPath' -exec basename {} \;"
        
        # Use the authenticated SSH connection
        Write-Host "    Executing: ssh $remoteHost '$scanCommand'"
        $availableFolders = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $scanCommand 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    [ERROR] Could not scan remote directory"
            Write-Host "    Command output: $availableFolders"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Could not scan remote directory: $remoteRepoPath`n`nPlease ensure the directory exists and is accessible.", "Remote Scan Error", "OK", "Error")
            exit 1
        }
        
        # Convert output to array and filter out empty lines
        $folderList = $availableFolders -split "`n" | Where-Object { $_.Trim() -ne "" }
        
        if ($folderList.Count -eq 0) {
            Write-Host "    [ERROR] No subdirectories (and thus no simulation models) found in:"
            Write-Host "    $remoteRepoPath"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("No subdirectories (and thus no simulation models) found in: $remoteRepoPath`n`nPlease ensure there are subdirectories containing your simulation models and their respective GitHub repositories.", "No Repositories Found", "OK", "Warning")
            exit 1
        }
        
        Write-Host "    [SUCCESS] Found $($folderList.Count) repositories:"
        Write-Host ""
        foreach ($folder in $folderList) {
            Write-Host "        - $folder"
        }
        Write-Host ""
        
    } catch {
        Write-Host "    [ERROR] Unexpected error while scanning remote repositories"
        Write-Host "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Unexpected error while scanning remote for simulation models and repositories.`n`nError: $($_.Exception.Message)", "Scan Error", "OK", "Error")
        exit 1
    }

#---------------------------------------------------#
#   STEP 4.1.3: IF REMOTE - PROMPT REPO SELECTION   #
#---------------------------------------------------#

    Write-Host ""
    Write-Host "-----------------------------------------"
    Write-Host "    REPOSITORY SELECTION"
    Write-Host "-----------------------------------------"
    Write-Host ""
    
    Write-Host "    [INFO] Creating repository selection dialog..."
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
        Write-Host "    [SUCCESS] Selected repository: $($script:SELECTED_REPO)"
        Write-Host "    Repository path: $remoteRepoPath/$($script:SELECTED_REPO)"
        Write-Host ""
        
        # Verify the selected repository exists and contains a Git repository
        Write-Host "    [INFO] Verifying selected repository..."
        
        # Ensure we're using the correct remote host for verification
        if ([string]::IsNullOrEmpty($remoteHost)) {
            if ($script:REMOTE_HOST_IP) {
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                Write-Host "    [INFO] Using remote host: $remoteHost"
            } else {
                Write-Host "    [ERROR] No remote host information available for verification"
            }
        }
        
        $gitCheckCommand = "test -d '$remoteRepoPath/$($script:SELECTED_REPO)/.git' && echo 'Git repository found' || echo 'No Git repository'"
        $gitCheckResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost $gitCheckCommand 2>&1
        
        if ($gitCheckResult -match "Git repository found") {
            Write-Host "    [SUCCESS] Git repository found in selected folder"
        } else {
            Write-Host "    [WARNING] No .git directory found in selected folder"
            Write-Host "    This folder may not be a Git repository"
        }
        Write-Host ""
        
    } else {
        Write-Host "    [ERROR] User cancelled repository selection"
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
    
    Write-Host "    [INFO] Setting up Docker context for remote execution..."
    Write-Host "    Remote host: $remoteHost"
    Write-Host "    Selected repository: $($script:SELECTED_REPO)"
    Write-Host "    Remote repository path: $remoteRepoPath/$($script:SELECTED_REPO)"
    Write-Host ""

    # Store the full remote path for later use
    $script:REMOTE_REPO_PATH = "$remoteRepoPath/$($script:SELECTED_REPO)"
    
    # Verify Docker is available on remote host
    Write-Host "    [INFO] Checking remote Docker availability..."
    Write-Host ""
    try {
        # Ensure we have the correct remote host for Docker verification
        if ([string]::IsNullOrEmpty($remoteHost)) {
            if ($script:REMOTE_HOST_IP) {
                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                Write-Host "    [INFO] Using remote host for Docker verification: $remoteHost"
            } else {
                Write-Host "    [ERROR] No remote host information available for Docker verification"
                exit 1
            }
        }
        
        $dockerVersion = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker --version" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker is available on remote host"
            Write-Host "    Remote Docker version: $dockerVersion"
            Write-Host ""
            
            # Ensure Docker engine is running on remote host
            Write-Host "    [INFO] Checking remote Docker engine status..."
            & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker info" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [WARNING] Docker engine is not running on remote host"
                Write-Host "    Attempting to start Docker service on Ubuntu 24.04..."
                Write-Host ""
                
                try {
                    # Try to start Docker service on Ubuntu (systemd)
                    # First, check if user can run Docker without sudo (is in docker group)
                    Write-Host "    Checking if user can run Docker without sudo..."
                    $dockerGroupCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "groups | grep -q docker && echo 'HAS_DOCKER_GROUP' || echo 'NO_DOCKER_GROUP'" 2>&1
                    
                    if ($dockerGroupCheck -match "HAS_DOCKER_GROUP") {
                        Write-Host "    [INFO] User is in docker group, trying Docker without sudo..."
                        # Try starting Docker service as regular user (if systemd allows)
                        $startResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "systemctl --user start docker || echo 'USER_START_FAILED'" 2>&1
                        if ($startResult -match "USER_START_FAILED") {
                            Write-Host "    [INFO] User-level start failed, need system-level Docker service"
                            $needsSudo = $true
                        } else {
                            Write-Host "    [SUCCESS] Docker service started at user level"
                            $needsSudo = $false
                        }
                    } else {
                        Write-Host "    [INFO] User not in docker group, system-level service required"
                        $needsSudo = $true
                    }
                    
                    if ($needsSudo) {
                        Write-Host "    [INFO] System-level Docker service management required"
                        Write-Host "    Checking sudo access for Docker service..."
                        
                        # Check if passwordless sudo is available for systemctl docker
                        $sudoCheck = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "sudo -n systemctl status docker >/dev/null 2>&1 && echo 'SUDO_OK' || echo 'SUDO_NEEDS_PASSWORD'" 2>&1
                        
                        if ($sudoCheck -match "SUDO_OK") {
                            Write-Host "    [SUCCESS] Passwordless sudo available for Docker service"
                            $startResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "sudo systemctl start docker" 2>&1
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "    [SUCCESS] Docker service started via sudo"
                            } else {
                                Write-Host "    [WARNING] Could not start Docker service via sudo: $startResult"
                            }
                        } else {
                            Write-Host "    [WARNING] Sudo requires password for Docker service management"
                            Write-Host "    Cannot start Docker service automatically via SSH batch mode"
                            
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
                    Write-Host "    Waiting for remote Docker daemon to initialize..."
                    $maxAttempts = 30  # 30 seconds max wait
                    $attempt = 0
                    
                    do {
                        Start-Sleep -Seconds 1
                        $attempt++
                        Write-Host "    Checking remote Docker daemon status... ($attempt/$maxAttempts)" -NoNewline
                        
                        & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker info" 2>&1 | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host " [SUCCESS]"
                            break
                        } else {
                            Write-Host ""
                        }
                        
                        # Show different messages at different intervals
                        if ($attempt -eq 10) {
                            Write-Host "    [INFO] Remote Docker is still starting up (this may take a moment)..."
                        } elseif ($attempt -eq 20) {
                            Write-Host "    [INFO] Still waiting for remote Docker daemon (almost ready)..."
                        }
                        
                    } while ($attempt -lt $maxAttempts)
                    
                    # Final check
                    & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "docker info" 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    [SUCCESS] Remote Docker engine started successfully!"
                        Write-Host "    Startup time: $attempt seconds"
                    } else {
                        Write-Host "    [WARNING] Remote Docker engine did not start within $maxAttempts seconds"
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
                            Write-Host "    [INFO] Please start Docker on remote host manually"
                            [System.Windows.Forms.MessageBox]::Show("Please start Docker on the remote host manually:`n`nsudo systemctl start docker`nsudo systemctl enable docker`n`nThen click OK to continue.", "Manual Start Required", "OK", "Information")
                        } elseif ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                            Write-Host "    [INFO] User chose to exit"
                            exit 1
                        }
                        # If Yes is chosen, continue with warning
                    }
                    
                } catch {
                    Write-Host "    [ERROR] Failed to start remote Docker service"
                    Write-Host "    Error: $($_.Exception.Message)"
                    Write-Host "    Please start Docker on remote host manually"
                }
                
            } else {
                Write-Host "    [SUCCESS] Remote Docker engine is running"
            }
            Write-Host ""
        } else {
            Write-Host "    [ERROR] Docker is not available on remote host"
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
        Write-Host "    [ERROR] Could not check remote Docker availability"
        Write-Host "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Could not verify remote Docker availability.`n`nError: $($_.Exception.Message)`n`nPlease ensure the remote host is accessible and Docker is installed.", "Remote Docker Check Failed", "OK", "Error")
        exit 1
    }
    
    # Create/use a REMOTE Docker context over SSH
    # Requires SSH access to a host that already has a Docker Engine running (Ubuntu 24.04)
    # The remote host uses Unix socket: unix:///var/run/docker.sock
    Write-Host "    [INFO] Configuring Docker context for remote Ubuntu 24.04 host..."

    $RemoteContextName = "php_workstation"  # Name for the Docker context

    # Ensure we have the correct remote host for Docker context
    if ([string]::IsNullOrEmpty($remoteHost)) {
        if ($script:REMOTE_HOST_IP) {
            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
            Write-Host "    [INFO] Using remote host for Docker context: $remoteHost"
        } else {
            Write-Host "    [ERROR] No remote host information available for Docker context"
            exit 1
        }
    }

    # Check if the context already exists
    Write-Host "    [INFO] Checking for existing Docker context..."
    $existing = & docker context ls --format '{{.Name}}' 2>$null
    $exists = $existing -contains $RemoteContextName

    if (-not $exists) {
        Write-Host "    [INFO] Creating Docker context '$RemoteContextName' for ssh://$remoteHost..."
        & docker context create $RemoteContextName `
            --description "Remote Docker engine over SSH (Ubuntu 24.04)" `
            --docker "host=ssh://$remoteHost"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker context created successfully"
        } else {
            Write-Host "    [ERROR] Failed to create Docker context"
        }
    } else {
        Write-Host "    [INFO] Context '$RemoteContextName' already exists"
    }
    Write-Host ""

    # Switch to the remote context
    Write-Host "    [INFO] Switching to context '$RemoteContextName'..."
    & docker context use $RemoteContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Successfully switched to remote Docker context"
    } else {
        Write-Host "    [WARNING] Failed to switch Docker context"
    }
    Write-Host ""

    # Test remote Docker connection
    Write-Host "    [INFO] Testing remote Docker connection..."
    & docker --context $RemoteContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Remote Docker connection test passed"
    } else {
        Write-Host "    [WARNING] Remote Docker connection test failed"
    }
    Write-Host ""

    Write-Host "    [SUCCESS] Remote Docker environment is set up and ready to use!"
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
    
    Write-Host "    [INFO] Selecting local repository folder for container mounting..."
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
    
    Write-Host "    [INFO] Opening folder selection dialog..."
    Write-Host ""
    $folderResult = $folderBrowser.ShowDialog()
    
    if ($folderResult -eq [System.Windows.Forms.DialogResult]::OK) {
        $selectedPath = $folderBrowser.SelectedPath
        Write-Host "    [INFO] Selected local folder: $selectedPath"
        Write-Host ""
        
        # Validate that a folder was actually selected
        if ([string]::IsNullOrWhiteSpace($selectedPath) -or -not (Test-Path $selectedPath)) {
            Write-Host "    [ERROR] Invalid folder selection"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Please select a valid folder containing your repository.", "Invalid Selection", "OK", "Error")
            exit 1
        }
        
        # Store the full local path
        $script:LOCAL_REPO_PATH = $selectedPath
        
        # Extract the repository name (last folder in the path)
        $script:SELECTED_REPO = Split-Path $selectedPath -Leaf
        
        Write-Host "    [SUCCESS] Local repository path: $($script:LOCAL_REPO_PATH)"
        Write-Host "    [SUCCESS] Repository name: $($script:SELECTED_REPO)"
        Write-Host ""
        
        # Check if the selected folder contains a Git repository
        $gitPath = Join-Path $selectedPath ".git"
        if (Test-Path $gitPath) {
            Write-Host "    [SUCCESS] Git repository detected in selected folder"
        } else {
            Write-Host "    [WARNING] No .git directory found in selected folder"
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
                Write-Host "    [INFO] User chose not to continue without Git repository"
                Write-Host ""
                exit 1
            } else {
                Write-Host "    [INFO] User chose to continue without Git repository"
                Write-Host ""
            }
        }
        
    } else {
        Write-Host "    [ERROR] User cancelled folder selection"
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
    
    Write-Host "    [INFO] Setting up Docker context for local execution..."
    Write-Host "    Selected repository: $($script:SELECTED_REPO)"
    Write-Host "    Local repository path: $($script:LOCAL_REPO_PATH)"
    Write-Host ""
    
    # Verify Docker is available locally
    Write-Host "    [INFO] Checking local Docker availability..."
    Write-Host ""
    try {
        $dockerVersion = & docker --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker is available locally"
            Write-Host "    Docker version: $dockerVersion"
            Write-Host ""
            
            # Ensure Docker engine is running
            Write-Host "    [INFO] Checking Docker engine status..."
            & docker info 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Host "    [WARNING] Docker engine is not running"
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
                            Write-Host "    [WARNING] Docker Desktop executable not found in standard locations"
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
                            Write-Host " [SUCCESS]"
                            break
                        } else {
                            Write-Host ""
                        }
                        
                        # Show different messages at different intervals
                        if ($attempt -eq 10) {
                            Write-Host "    [INFO] Docker is still starting up (this may take a moment)..."
                        } elseif ($attempt -eq 20) {
                            Write-Host "    [INFO] Still waiting for Docker daemon (almost ready)..."
                        }
                        
                    } while ($attempt -lt $maxAttempts)
                    
                    # Final check
                    & docker info 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    [SUCCESS] Docker engine started successfully!"
                        Write-Host "    Startup time: $attempt seconds"
                    } else {
                        Write-Host "    [WARNING] Docker engine did not start within $maxAttempts seconds"
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
                            Write-Host "    [INFO] Please start Docker Desktop manually and click OK when ready"
                            [System.Windows.Forms.MessageBox]::Show("Please start Docker Desktop manually and wait for it to be ready, then click OK to continue.", "Manual Start Required", "OK", "Information")
                        } elseif ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
                            Write-Host "    [INFO] User chose to exit"
                            exit 1
                        }
                        # If No is chosen, continue with warning
                    }
                    
                } catch {
                    Write-Host "    [ERROR] Failed to start Docker Desktop"
                    Write-Host "    Error: $($_.Exception.Message)"
                    Write-Host "    Please start Docker Desktop manually"
                }
                
            } else {
                Write-Host "    [SUCCESS] Docker engine is running"
            }
            Write-Host ""
        } else {
            Write-Host "    [ERROR] Docker is not available locally"
            Write-Host ""
            [System.Windows.Forms.MessageBox]::Show("Docker is not available on this system.`n`nPlease ensure Docker Desktop is installed and running.", "Docker Not Available", "OK", "Error")
            exit 1
        }
    } catch {
        Write-Host "    [ERROR] Could not check Docker availability"
        Write-Host "    Error details: $($_.Exception.Message)"
        Write-Host ""
        [System.Windows.Forms.MessageBox]::Show("Could not verify Docker availability.`n`nPlease ensure Docker Desktop is installed and running.", "Docker Check Failed", "OK", "Error")
        exit 1
    }
    
    Write-Host "    [INFO] Setting up local Docker context..."
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
    Write-Host "    [INFO] Checking for existing Docker context..."
    $exists = (& docker context ls --format '{{.Name}}' 2>$null) -contains $LocalContextName

    if (-not $exists) {
        Write-Host "    [INFO] Creating Docker context '$LocalContextName' for $dockerHost..."
        & docker context create $LocalContextName --description "Local Docker engine" --docker "host=$dockerHost"
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [SUCCESS] Docker context created successfully"
        } else {
            Write-Host "    [ERROR] Failed to create Docker context"
        }
    } else {
        Write-Host "    [INFO] Context '$LocalContextName' already exists"
    }
    Write-Host ""

    # Switch to the local context
    Write-Host "    [INFO] Switching to context '$LocalContextName'..."
    & docker context use $LocalContextName *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Successfully switched to local Docker context"
    } else {
        Write-Host "    [WARNING] Failed to switch Docker context"
    }
    Write-Host ""

    # Quick smoke test
    Write-Host "    [INFO] Testing Docker connection..."
    & docker --context $LocalContextName version 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [SUCCESS] Docker connection test passed"
    } else {
        Write-Host "    [WARNING] Docker connection test failed"
    }
    Write-Host ""

    Write-Host "    [SUCCESS] Local Docker environment is set up and ready to use!"
    Write-Host ""

} else {
    Write-Host ""
    Write-Host "    [ERROR] Invalid container location state"
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

Write-Host "[INFO] Checking for existing containers for user: $USERNAME"
Write-Host ""

try {
    # Get all containers (running and stopped) that contain the username
    $existingContainers = & docker ps -a --filter "name=_$USERNAME" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>$null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARNING] Could not check for existing containers. Consider checking manually in Docker Desktop!"
        Write-Host "  Continuing with container launch..."
        Write-Host ""
    } else {
        # Parse the output to find containers
        $containerList = $existingContainers -split "`n" | Where-Object { $_ -match "_$USERNAME" -and $_ -notmatch "^NAMES" }
        
        if ($containerList.Count -gt 0) {
            Write-Host "[INFO] Found existing containers for user '$USERNAME':"
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
                Write-Host "[WARNING] Found $($runningList.Count) RUNNING container(s) for user '$USERNAME':"
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
                    Write-Host "[INFO] User chose to stop existing containers"
                    Write-Host ""
                    Write-Host "Stopping existing containers for user '$USERNAME'..."
                    
                    foreach ($runningContainer in $runningList) {
                        if ($runningContainer.Trim() -ne "") {
                            Write-Host "  Stopping container: $runningContainer"
                            & docker stop $runningContainer 2>$null
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "    [SUCCESS] Stopped: $runningContainer"
                            } else {
                                Write-Host "    [WARNING] Could not stop: $runningContainer"
                            }
                        }
                    }
                    Write-Host ""
                    Write-Host "[SUCCESS] Container cleanup completed"
                    
                } elseif ($result -eq [System.Windows.Forms.DialogResult]::No) {
                    Write-Host "[INFO] User chose to continue with existing containers running"
                    Write-Host "[WARNING] Proceeding with existing containers running may cause conflicts"
                    
                } else {
                    Write-Host "[INFO] User cancelled container launch"
                    Write-Host "Please manage existing containers manually using:"
                    Write-Host "  docker ps -a                    # List all containers"
                    Write-Host "  docker stop <container_name>    # Stop a container"
                    Write-Host "  docker rm <container_name>      # Remove a container"
                    Write-Host "Otherwise use Docker Desktop app!"
                    Write-Host ""
                    exit 0
                }
            } else {
                Write-Host "[INFO] Found existing containers, but none are currently running"
                Write-Host "  These stopped containers will not interfere with new containers"
                Write-Host ""
            }
        } else {
            Write-Host "[INFO] No existing containers found for user '$USERNAME'"
            Write-Host "  Ready to create new container: $CONTAINER_NAME"
            Write-Host ""
        }
    }} catch {
    Write-Host "[WARNING] Error checking for existing containers: $($_.Exception.Message)"
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

Write-Host "[INFO] Preparing container management interface..."
Write-Host "  Container Name: $CONTAINER_NAME"
Write-Host "  Selected Repository: $($script:SELECTED_REPO)"
Write-Host "  Username: $USERNAME"
Write-Host ""

# Check if the specific container is currently running
$isContainerRunning = $false
try {
    $runningCheck = & docker ps --filter "name=^${CONTAINER_NAME}$" --format "{{.Names}}" 2>$null
    if ($LASTEXITCODE -eq 0 -and $runningCheck.Trim() -eq $CONTAINER_NAME) {
        $isContainerRunning = $true
        Write-Host "[INFO] Container '$CONTAINER_NAME' is currently RUNNING"
    } else {
        Write-Host "[INFO] Container '$CONTAINER_NAME' is currently STOPPED or does not exist"
    }
} catch {
    Write-Host "[WARNING] Could not check container status: $($_.Exception.Message)"
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
    Write-Host "[INFO] Start button clicked"
    Write-Host "  Container: $CONTAINER_NAME"
    
    # Get options from form
    $useVolumes = $checkBoxVolumes.Checked
    $portOverride = $textBoxPort.Text.Trim()
    $customParams = $textBoxParams.Text.Trim()
    $simDesignFile = $textBoxSimDesign.Text.Trim()
    
    Write-Host "  Advanced Options:"
    Write-Host "    Use Volumes: $useVolumes"
    Write-Host "    Port Override: $(if($portOverride) { $portOverride } else { 'Default' })"
    Write-Host "    Custom Parameters: $(if($customParams) { $customParams } else { 'None' })"
    Write-Host "    sim_design.yaml file: $(if($simDesignFile) { $simDesignFile } else { 'Default' })"
    Write-Host ""
    
    # TODO: Implement container start logic here
    [System.Windows.Forms.MessageBox]::Show("Container start logic will be implemented here.`n`nContainer: $CONTAINER_NAME`nOptions: Use Volumes=$useVolumes, Port=$portOverride, Params=$customParams, SimDesign=$simDesignFile", "Start Container", "OK", "Information")
    


    #######################################################################
    

# Resolve docker setup directory based on current model
if (-not $script:LOCAL_REPO_PATH -and -not $script:REMOTE_REPO_PATH) {
    Write-Host "[FATAL ERROR] No path for repository or model found. Please restart the application and select a folder."
    Exit 1
} elseif (Test-Path $script:LOCAL_REPO_PATH) {
    $ScriptDir = "$script:LOCAL_REPO_PATH\docker_setup"
    Write-Host "[INFO] Using local repository path: $script:LOCAL_REPO_PATH"
} elseif (Test-Path $script:REMOTE_REPO_PATH) {
    $ScriptDir = "$script:REMOTE_REPO_PATH/docker_setup"
    Write-Host "[INFO] Using remote repository path: $script:REMOTE_REPO_PATH"
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

Write-Host "[INFO] Using configuration file: $SimDesignYaml"

# Check if Docker image for the current model already exists
$DockerImageName = $script:SELECTED_REPO.ToLower()
Write-Host "[INFO] Checking for Docker image: $DockerImageName"

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
    Write-Host "[WARNING] Could not check for existing Docker image: $($_.Exception.Message)"
    $imageExists = $false
}

if ($imageExists) {
    Write-Host "[SUCCESS] Docker image '$DockerImageName' that can be used for your containeralready exists"
} else {
    Write-Host "[INFO] Docker image '$DockerImageName' does not exist, building from Dockerfile..."
    
    # Determine Dockerfile path
    if ($CONTAINER_LOCATION -eq "LOCAL") {
        $dockerfilePath = Join-Path $script:LOCAL_REPO_PATH "docker_setup\Dockerfile.IMPACTncdGER"
        $dockerContextPath = Join-Path $script:LOCAL_REPO_PATH "docker_setup"
    } else {
        $dockerfilePath = "$script:REMOTE_REPO_PATH/docker_setup/Dockerfile.IMPACTncdGER"
        $dockerContextPath = "$script:REMOTE_REPO_PATH/docker_setup"
    }
    
    Write-Host "[INFO] Using Dockerfile: $dockerfilePath"
    Write-Host "[INFO] Docker build context: $dockerContextPath"
    
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
        Write-Host "[ERROR] Could not check for Dockerfile: $($_.Exception.Message)"
        $dockerfileExists = $false
    }
    
    if (-not $dockerfileExists) {
        Write-Host "[FATAL ERROR] Dockerfile not found at: $dockerfilePath"
        Write-Host "Please ensure 'Dockerfile.IMPACTncdGER' exists in the docker_setup folder of your repository."
        Exit 1
    }
    
    # Build the Docker image
    Write-Host "[INFO] Building Docker image '$DockerImageName'..."
    Write-Host "This may take several minutes depending on the image size and dependencies..."
    
    try {
        if ($CONTAINER_LOCATION -eq "LOCAL") {
            # Local build
            $buildResult = & docker build -f $dockerfilePath -t $DockerImageName $dockerContextPath 2>&1
            $buildSuccess = $LASTEXITCODE -eq 0
        } else {
            # Remote build
            $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
            $buildCommand = "cd '$dockerContextPath' && docker build -f '$dockerfilePath' -t '$DockerImageName' ."
            $buildResult = & ssh -o ConnectTimeout=30 -o BatchMode=yes $remoteHost $buildCommand 2>&1
            $buildSuccess = $LASTEXITCODE -eq 0
        }
        
        if ($buildSuccess) {
            Write-Host "[SUCCESS] Docker image '$DockerImageName' built successfully!"
        } else {
            Write-Host "[WARNING] Failed to build Docker image '$DockerImageName' on first attempt"
            Write-Host "Build output:"
            Write-Host $buildResult
            Write-Host ""
            Write-Host "[INFO] Attempting fallback: building prerequisite image first..."
            
            # Determine prerequisite Dockerfile path
            if ($CONTAINER_LOCATION -eq "LOCAL") {
                $prereqDockerfilePath = Join-Path $script:LOCAL_REPO_PATH "docker_setup\Dockerfile.prerequisite.IMPACTncdGER"
            } else {
                $prereqDockerfilePath = "$script:REMOTE_REPO_PATH/docker_setup/Dockerfile.prerequisite.IMPACTncdGER"
            }
            
            Write-Host "[INFO] Using prerequisite Dockerfile: $prereqDockerfilePath"
            
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
                Write-Host "[ERROR] Could not check for prerequisite Dockerfile: $($_.Exception.Message)"
                $prereqDockerfileExists = $false
            }
            
            if ($prereqDockerfileExists) {
                Write-Host "[INFO] Building prerequisite Docker image..."
                $prereqImageName = "$DockerImageName-prerequisite"
                
                try {
                    if ($CONTAINER_LOCATION -eq "LOCAL") {
                        # Local build of prerequisite
                        $prereqBuildResult = & docker build -f $prereqDockerfilePath -t $prereqImageName $dockerContextPath 2>&1
                        $prereqBuildSuccess = $LASTEXITCODE -eq 0
                    } else {
                        # Remote build of prerequisite
                        $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                        $prereqBuildCommand = "cd '$dockerContextPath' && docker build -f '$prereqDockerfilePath' -t '$prereqImageName' ."
                        $prereqBuildResult = & ssh -o ConnectTimeout=30 -o BatchMode=yes $remoteHost $prereqBuildCommand 2>&1
                        $prereqBuildSuccess = $LASTEXITCODE -eq 0
                    }
                    
                    if ($prereqBuildSuccess) {
                        Write-Host "[SUCCESS] Prerequisite image built successfully! Retrying main image build..."
                        
                        # Retry building the main image TODO: Add logic that it does not try to build from kalleef account but uses the local prereq image!
                        try {
                            if ($CONTAINER_LOCATION -eq "LOCAL") {
                                # Local build retry
                                $retryBuildResult = & docker build -f $dockerfilePath -t $DockerImageName $dockerContextPath 2>&1
                                $retryBuildSuccess = $LASTEXITCODE -eq 0
                            } else {
                                # Remote build retry
                                $remoteHost = "php-workstation@$($script:REMOTE_HOST_IP)"
                                $retryBuildCommand = "cd '$dockerContextPath' && docker build -f '$dockerfilePath' -t '$DockerImageName' ."
                                $retryBuildResult = & ssh -o ConnectTimeout=30 -o BatchMode=yes $remoteHost $retryBuildCommand 2>&1
                                $retryBuildSuccess = $LASTEXITCODE -eq 0
                            }
                            
                            if ($retryBuildSuccess) {
                                Write-Host "[SUCCESS] Docker image '$DockerImageName' built successfully after prerequisite build!"
                            } else {
                                Write-Host "[ERROR] Failed to build Docker image '$DockerImageName' even after building prerequisite"
                                Write-Host "Retry build output:"
                                Write-Host $retryBuildResult
                                Exit 1
                            }
                        } catch {
                            Write-Host "[ERROR] Exception occurred during retry build: $($_.Exception.Message)"
                            Exit 1
                        }
                    } else {
                        Write-Host "[ERROR] Failed to build prerequisite Docker image"
                        Write-Host "Prerequisite build output:"
                        Write-Host $prereqBuildResult
                        Exit 1
                    }
                } catch {
                    Write-Host "[ERROR] Exception occurred while building prerequisite image: $($_.Exception.Message)"
                    Exit 1
                }
            } else {
                Write-Host "[ERROR] Prerequisite Dockerfile not found at: $prereqDockerfilePath"
                Write-Host "[FATAL ERROR] Cannot build Docker image - both main and prerequisite Dockerfiles failed"
                Exit 1
            }
        }
    } catch {
        Write-Host "[ERROR] Exception occurred while building Docker image: $($_.Exception.Message)"
        Exit 1
    }
}

# TODO: Check whether we need the tag option!
# Determine the Docker image name based on the tag
#if ($Tag -eq "local") {
#    $ImageName = "impactncdjpn:local"
#} else {
#    $ImageName = "chriskypri/impactncdjpn:$Tag"
#}
#Write-Host "[INFO] ]Using Docker image: $ImageName"

# Use current user (for user-specific volume names)
# Sanitize username for Docker volume names (replace spaces and special characters with underscores)
$SafeCurrentUser = $USERNAME -replace '[^a-zA-Z0-9]', '_' -replace '__+', '_' -replace '^_|_$', ''
if ([string]::IsNullOrEmpty($SafeCurrentUser)) {
    $SafeCurrentUser = "dockeruser"
    Write-Host "[WARNING] Could not determine a valid username, using fallback: $SafeCurrentUser"
}

# Get user identity information for non-root Docker execution
# Note: On Windows, Docker Desktop runs containers in a Linux VM, so we use
# default UID/GID (1000:1000) which works well for most cases
$UserId = "1000"
$GroupId = "1000"
$UserName = $USERNAME
# Use a safe group name - if it conflicts, the entrypoint will create a fallback
$GroupName = "dockergroup"

# Define user-specific Docker volume names using sanitized username (only for output and synthpop)
$VolumeOutput    = "impactncd_germany_output_$SafeCurrentUser"
$VolumeSynthpop  = "impactncd_germany_synthpop_$SafeCurrentUser"

# Call the function passing $ProjectRoot
$outputDir    = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "output_dir" -BaseDir $ProjectRoot
$synthpopDir  = Get-YamlPathValue -YamlPath $SimDesignYaml -Key "synthpop_dir" -BaseDir $ProjectRoot

# Validate or create output directory
if (-not (Test-AndCreateDirectory -Path $outputDir -PathKey "output_dir")) {
    Pop-Location
    Exit 1
}

# Validate or create synthpop directory
if (-not (Test-AndCreateDirectory -Path $synthpopDir -PathKey "synthpop_dir")) {
    Pop-Location
    Exit 1
}

Write-Host "[INFO] Mounting output_dir:    $outputDir"       # Keep using forward slashes for Docker mounts
Write-Host "[INFO] Mounting synthpop_dir:  $synthpopDir"      # Keep using forward slashes for Docker mounts



# -----------------------------
# Run Docker container
# -----------------------------
if ($UseVolumes) {
    Write-Host "`nUsing Docker volumes for outputs and synthpop..."

    # Build rsync-alpine image if it doesn't already exist.
    $rsyncImage = "rsync-alpine"
    docker image inspect $rsyncImage > $null 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Building rsync-alpine image..."
        
        # Check if Dockerfile.rsync exists
        $DockerfileRsync = Join-Path $ScriptDir "Dockerfile.rsync"
        if (Test-Path $DockerfileRsync) {
            Write-Host "Using Dockerfile.rsync..."
            docker build -f "$DockerfileRsync" -t $rsyncImage $ScriptDir
        } else {
            Write-Host "Dockerfile.rsync not found, creating rsync image inline..."
            $InlineDockerfile = @"
FROM alpine:latest
RUN apk add --no-cache rsync
"@
            $InlineDockerfile | docker build -t $rsyncImage -
        }
    } else {
        Write-Host "Using existing rsync-alpine image."
    }

    # Ensure local output directories exist
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
    if (-not (Test-Path $synthpopDir)) { New-Item -ItemType Directory -Path $synthpopDir | Out-Null }

    # Remove any existing volumes (ignore errors if not removable)
    Write-Host "Removing any existing volumes (if possible)..."
    docker volume rm $VolumeOutput -f 2>$null
    docker volume rm $VolumeSynthpop -f 2>$null

    # Create fresh Docker-managed volumes
    docker volume create $VolumeOutput | Out-Null
    docker volume create $VolumeSynthpop | Out-Null

    # Fix volume ownership and pre-populate volumes:
    # Docker volumes are created with root ownership by default. We need to fix
    # the ownership before we can populate them as the calling user.
    Write-Host "Setting correct ownership for Docker volumes..."
    docker run --rm -v "${VolumeOutput}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"
    docker run --rm -v "${VolumeSynthpop}:/volume" alpine sh -c "chown ${UserId}:${GroupId} /volume"

    # Pre-populate volumes:
    # The output and synthpop volumes are populated from the respective local folders.
    Write-Host "Populating output volume from local folder..."
    # Use permission-tolerant copy with fallback logic
    docker run --rm --user "${UserId}:${GroupId}" -v "${outputDir}:/source" -v "${VolumeOutput}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"
    Write-Host "Populating synthpop volume from local folder..."
    # Use permission-tolerant copy with fallback logic
    docker run --rm --user "${UserId}:${GroupId}" -v "${synthpopDir}:/source" -v "${VolumeSynthpop}:/volume" alpine sh -c "cp -r /source/. /volume/ 2>/dev/null || cp -a /source/. /volume/ 2>/dev/null || true"

    # Run the main container with volumes mounted.
    Write-Host "Running the main container using Docker volumes..."
    # Construct arguments as an array for reliable passing
    $dockerArgs = @(
        "run", "-it", "--rm",
        # User identity environment variables
        "-e", "USER_ID=$UserId",
        "-e", "GROUP_ID=$GroupId", 
        "-e", "USER_NAME=$UserName",
        "-e", "GROUP_NAME=$GroupName",
        # Use -v syntax within the array elements (no project volume needed)
        "-v", "${VolumeOutput}:/output",
        "-v", "${VolumeSynthpop}:/synthpop"
    )
    
    # Add scenarios mount if provided
    if ($ScenariosDir) {
        $DockerScenariosDir = Convert-PathToDockerFormat -Path $ScenariosDir
        $dockerArgs += "--mount"
        $dockerArgs += "type=bind,source=$DockerScenariosDir,target=/IMPACTncd_Japan/scenarios"
    }
    
    # Add final arguments
    $dockerArgs += "--workdir"
    $dockerArgs += "/IMPACTncd_Japan"
    $dockerArgs += $ImageName
    $dockerArgs += "bash"
    
    # Execute docker with the arguments array
    & docker $dockerArgs

    # After the container exits:
    # Synchronize the output and synthpop volumes back to the local directories using rsync.
    Write-Host "Container exited. Syncing volumes back to local directories using rsync (checksum mode)..."
    # Use ${} to delimit variable name before the colon and add permission flags
    # Added --no-perms and --chmod=ugo=rwX to prevent permission issues on Windows
    docker run --rm --user "${UserId}:${GroupId}" -v "${VolumeOutput}:/volume" -v "${outputDir}:/backup" $rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/
    docker run --rm --user "${UserId}:${GroupId}" -v "${VolumeSynthpop}:/volume" -v "${synthpopDir}:/backup" $rsyncImage rsync -avc --no-owner --no-group --no-times --no-perms --chmod=ugo=rwX /volume/ /backup/

    # Clean up all the Docker volumes used for the simulation.
    Write-Host "Cleaning up Docker volumes..."
    docker volume rm $VolumeOutput | Out-Null
    docker volume rm $VolumeSynthpop | Out-Null

} else {
    Write-Host "`nUsing direct bind mounts for outputs and synthpop..."

    # Convert paths for Docker bind mount
    $DockerOutputDir = Convert-PathToDockerFormat -Path $outputDir
    $DockerSynthpopDir = Convert-PathToDockerFormat -Path $synthpopDir

    Write-Host "Docker Output Dir:   $DockerOutputDir"
    Write-Host "Docker Synthpop Dir: $DockerSynthpopDir"

    # Pass mount arguments correctly to docker run (no project mount needed)
    if ($ScenariosDir) {
        $DockerScenariosDir = Convert-PathToDockerFormat -Path $ScenariosDir
        docker run -it --rm `
            -e "USER_ID=$UserId" `
            -e "GROUP_ID=$GroupId" `
            -e "USER_NAME=$UserName" `
            -e "GROUP_NAME=$GroupName" `
            --mount "type=bind,source=$DockerOutputDir,target=/output" `
            --mount "type=bind,source=$DockerSynthpopDir,target=/synthpop" `
            --mount "type=bind,source=$DockerScenariosDir,target=/IMPACTncd_Japan/scenarios" `
            --workdir /IMPACTncd_Japan `
            $ImageName `
            bash
    } else {
        docker run -it --rm `
            -e "USER_ID=$UserId" `
            -e "GROUP_ID=$GroupId" `
            -e "USER_NAME=$UserName" `
            -e "GROUP_NAME=$GroupName" `
            --mount "type=bind,source=$DockerOutputDir,target=/output" `
            --mount "type=bind,source=$DockerSynthpopDir,target=/synthpop" `
            --workdir /IMPACTncd_Japan `
            $ImageName `
            bash
    }
}



    #######################################################################

    # Update UI state (placeholder - will be updated after actual container start)
    # $buttonStart.Enabled = $false
    # $buttonStop.Enabled = $true
})

$buttonStop.Add_Click({
    Write-Host ""
    Write-Host "[INFO] Stop button clicked"
    Write-Host "  Container: $CONTAINER_NAME"
    Write-Host ""
    


    # TODO: Implement container stop logic here
    #[System.Windows.Forms.MessageBox]::Show("Container stop logic will be implemented here.`n`nContainer: $CONTAINER_NAME", "Stop Container", "OK", "Information")
    
    # Update UI state (placeholder - will be updated after actual container stop)
    # $buttonStart.Enabled = $true
    # $buttonStop.Enabled = $false
})

$buttonOK.Add_Click({
    Write-Host "[INFO] Container management dialog closed"
    $formContainer.Close()
})

# Show the container management dialog
Write-Host "Showing container management interface..."
$containerResult = $formContainer.ShowDialog()

Write-Host ""
Write-Host "Container management interface closed."
Write-Host ""



<#
Logic:
    5. After the user clicks start:
        - We check whether an image for the repository/model already exists
        - If not, we pull the pre-requisite image from Docker Hub and compile the model image
        - If yes, we check whether the user wants to rebuild the image or use the existing one
        - If yes, we rebuild the image
        - If no, we check whether a container based on the existing image already exists for the given user
            - If yes, we start the existing container
            - If no, we create and start a new container based on the existing image
            - Here the mounting logic is important (see below)
        - After the container is started we monitor its status and prompt the user with browser login instructions
        - The login instructions show the IP and the username and password the user has set at the very beginning
    6. While the container is running the script and start/stop prompt stays alive but the start button is disabled
    7. The user can stop the container at any time by clicking the stop button
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

# Show the form and keep script alive
[void]$form.ShowDialog()
