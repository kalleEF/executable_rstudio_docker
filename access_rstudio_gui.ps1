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
    Size = New-Object System.Drawing.Size(400,200)
    StartPosition = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox = $false
}

# Instruction label
$labelInstruction = New-Object System.Windows.Forms.Label -Property @{ 
    Text = "Please enter your username and a password`nfor your RStudio Server session:"
    Location = New-Object System.Drawing.Point(10,10)
    Size = New-Object System.Drawing.Size(380,30)
    Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 9, [System.Drawing.FontStyle]::Regular)
}
$form.Controls.Add($labelInstruction)

# Username label and textbox
$labelUser = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Username:'
    Location = New-Object System.Drawing.Point(10,50)
    Size = New-Object System.Drawing.Size(100,20)
}
$form.Controls.Add($labelUser)
$textUser = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(120,50)
    Size = New-Object System.Drawing.Size(250,20)
}
$form.Controls.Add($textUser)

# Password label and textbox
$labelPass = New-Object System.Windows.Forms.Label -Property @{ 
    Text = 'Password:'
    Location = New-Object System.Drawing.Point(10,80)
    Size = New-Object System.Drawing.Size(100,20)
}
$form.Controls.Add($labelPass)
$textPass = New-Object System.Windows.Forms.TextBox -Property @{ 
    Location = New-Object System.Drawing.Point(120,80)
    Size = New-Object System.Drawing.Size(250,20)
}
$form.Controls.Add($textPass)

# OK and Cancel buttons
$buttonOK = New-Object System.Windows.Forms.Button -Property @{
    Text = 'OK'
    Location = New-Object System.Drawing.Point(200,120)
    Size = New-Object System.Drawing.Size(75,30)
}
$form.Controls.Add($buttonOK)

$buttonCancel = New-Object System.Windows.Forms.Button -Property @{
    Text = 'Cancel'
    Location = New-Object System.Drawing.Point(290,120)
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
    $USERNAME = $textUser.Text.Trim()
    $PASSWORD = $textPass.Text
    Write-Host ""
    Write-Host "[SUCCESS] Credentials collected successfully"
    Write-Host "  Username: $USERNAME"
    Write-Host "  Password: $PASSWORD"
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "[ERROR] User cancelled the dialog - no credentials provided"
    Write-Host ""
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
    
    # Define SSH key paths
    $sshKeyPath = "$HOME\.ssh\id_ed25519_docker"
    $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_docker.pub"
    
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
        ssh-keygen -t ed25519 -C "IMPACT_Docker" -f $HOME\.ssh\id_ed25519_docker -N ""
        
        if (Test-Path $sshPublicKeyPath) {
            Write-Host ""
            Write-Host "[SUCCESS] SSH key generated successfully!"
            Write-Host ""
        } else {
            Write-Host ""
            Write-Host "[ERROR] Failed to generate SSH key!"
            Write-Host ""
            exit 1
        }

        # Show message box with public key only if new key was created
        $message = "It seems like you did not have an SSH key set up for Docker and GitHub.`n`n" +
                   "A new SSH public key has been generated.`n`n" +
                   "Please copy the key below and add it to your GitHub account:`n" +
                   "GitHub -> Settings -> SSH and GPG keys -> New SSH key`n`n" +
                   "Public Key:`n$publicKey`n`n" +
                   "The key has also been copied to your clipboard."
        
        # Copy to clipboard
        try {
            $publicKey | Set-Clipboard
            Write-Host "[SUCCESS] Public key copied to clipboard!"
        } catch {
            Write-Host "[WARNING] Could not copy to clipboard, but key is displayed."
        }

        # Show the message box
        [System.Windows.Forms.MessageBox]::Show($message, 'SSH Key Setup', 'OK', 'Information')

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
    Write-Host "Configuring for remote Docker containers..."
    Write-Host ""
    Write-Host "[INFO] Testing SSH connection to remote workstation..."
    
    # Define remote host (update this IP address to match your workstation)
    $remoteHost = "php-workstation@10.162.192.90"  # Update this to your actual remote host
 
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
            
            # Prompt user for remote host password
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
                if ([string]::IsNullOrWhiteSpace($textRemotePassword.Text)) {
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
                $remotePassword = $textRemotePassword.Text
                Write-Host "  [INFO] Password provided, testing connection..."
                Write-Host ""
                
                # Test connection with password using a more reliable method
                try {
                    Write-Host "  [INFO] Testing SSH connection with password..."
                    
                    # Method 1: Try using plink (PuTTY's command line tool) if available
                    $plinkPath = Get-Command plink.exe -ErrorAction SilentlyContinue
                    if ($plinkPath) {
                        Write-Host "  Using PuTTY plink for password authentication..."
                        
                        # Extract username and host parts
                        $hostParts = $remoteHost -split "@"
                        if ($hostParts.Count -eq 2) {
                            $sshUser = $hostParts[0]
                            $sshHost = $hostParts[1]
                        } else {
                            $sshUser = $env:USERNAME
                            $sshHost = $remoteHost
                        }
                        
                        # Test connection with plink
                        $plinkResult = & plink.exe -ssh -batch -pw $remotePassword -l $sshUser $sshHost "echo SSH_SUCCESS" 2>&1
                        
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
                        
                        # Create a batch file for SSH with password
                        $batchFile = [System.IO.Path]::GetTempFileName() + ".bat"
                        $expectScript = @"
@echo off
echo $remotePassword | ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no $remoteHost "echo SSH_SUCCESS" 2>nul
"@
                        Set-Content -Path $batchFile -Value $expectScript
                        
                        # Execute the batch file
                        $batchResult = & cmd.exe /c $batchFile 2>&1
                        Remove-Item $batchFile -Force -ErrorAction SilentlyContinue
                        
                        if ($batchResult -match "SSH_SUCCESS") {
                            Write-Host "  [SUCCESS] Password authentication successful!"
                            Write-Host ""
                            $authSuccess = $true
                        } else {
                            # Method 3: Try with sshpass if available (Windows Subsystem for Linux)
                            $sshpassTest = Get-Command sshpass -ErrorAction SilentlyContinue
                            if ($sshpassTest) {
                                Write-Host "  Trying with sshpass..."
                                $sshpassResult = & sshpass -p $remotePassword ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $remoteHost "echo SSH_SUCCESS" 2>&1
                                
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
                        $sshPublicKeyPath = "$HOME\.ssh\id_ed25519_docker.pub"
                        if (Test-Path $sshPublicKeyPath) {
                            $publicKeyContent = Get-Content $sshPublicKeyPath -Raw
                            $publicKeyContent = $publicKeyContent.Trim()
                            
                            Write-Host "  Copying SSH key to remote host..."
                            
                            # Use the same authentication method that worked for copying the key
                            if ($plinkPath) {
                                # Use plink to copy the SSH key
                                $keyCommand = "mkdir -p ~/.ssh && echo '$publicKeyContent' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo SSH_KEY_COPIED"
                                $keyCopyResult = & plink.exe -ssh -batch -pw $remotePassword -l $sshUser $sshHost $keyCommand 2>&1
                            } elseif ($sshpassTest) {
                                # Use sshpass to copy the SSH key
                                $keyCommand = "mkdir -p ~/.ssh && echo '$publicKeyContent' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo SSH_KEY_COPIED"
                                $keyCopyResult = & sshpass -p $remotePassword ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no $remoteHost $keyCommand 2>&1
                            } else {
                                # Use batch method to copy SSH key
                                $keyBatchFile = [System.IO.Path]::GetTempFileName() + ".bat"
                                $keyBatchScript = @"
@echo off
echo $remotePassword | ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o PasswordAuthentication=yes -o PubkeyAuthentication=no $remoteHost "mkdir -p ~/.ssh && echo '$publicKeyContent' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys && echo SSH_KEY_COPIED" 2>nul
"@
                                Set-Content -Path $keyBatchFile -Value $keyBatchScript
                                $keyCopyResult = & cmd.exe /c $keyBatchFile 2>&1
                                Remove-Item $keyBatchFile -Force -ErrorAction SilentlyContinue
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
                        
                    } else {
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
                    Write-Host "  [ERROR] Failed to test password authentication"
                    Write-Host "  Details: $($_.Exception.Message)"
                    Write-Host ""
                    [System.Windows.Forms.MessageBox]::Show("Failed to test password authentication.`n`nError: $($_.Exception.Message)", "Connection Error", "OK", "Error")
                    return
                }
                
            } else {
                Write-Host "  [INFO] User cancelled password authentication"
                Write-Host ""
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

#-----------------------------------------------------------------------#
#   STEP 5.1: IF REMOTE - LOGIC FOR MOUNTING FOLDERS AND COPY SSH KEY   #
#-----------------------------------------------------------------------#



#----------------------------------------------------------------------#
#   STEP 5.2: IF LOCAL - LOGIC FOR MOUNTING FOLDERS AND COPY SSH KEY   #
#----------------------------------------------------------------------#



#--------------------------------------------------------#
#   STEP 6: PROMPT FOR STARTING AND STOPPING CONTAINER   #
#--------------------------------------------------------#



# Show the form and keep script alive
[void]$form.ShowDialog()


#------------------------------------------------#
#   STEP 7: PROMPT AND LOGIC FOR GITHUB PROMPT   #
#------------------------------------------------#
