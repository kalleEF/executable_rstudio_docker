<#
 PowerShell GUI Launcher for RStudio Containers
 ---------------------------------------------
 This script prompts for username and password, then connects over SSH
 to start or create a Docker container, returning the URL for RStudio.
    Write-Host "Next: Add this key to GitHub -> Settings -> SSH and GPG keys -> New SSH key"
    Write-Host "==================================="
    Write-Host ""
}sage (uncompiled .ps1):
  - Open PowerShell console (not by double-clicking)
  - cd to script folder
  - Run: `PowerShell -E            Write-Host "[SUCCESS] Confirmed: Git repository found in selected         if (Test-Path $gitPath) {
            Write-Host "[SUCCESS] Git repository detected in selected folder"
        } else {
            Write-Host "[WARNING] No .git directory found in selected folder"er"
        } else {
                           # Check again
                    & docker info 2>&1 | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    [SUCCESS] Docker engine started successfully"
                    } else {
                        Write-Host "    [WARNING] Docker engine may still be starting up"
                        Write-Host "    Please wait a moment and try again"
                    }
                } catch {
                    Write-Host "    [WARNING] Could not automatically start Docker engine"
                    Write-Host "    Please start Docker Desktop manually"
                }
            } else {
                Write-Host "    [SUCCESS] Docker engine is running"
            } "[WARNING] No .git directory found in selected folder"utionPolicy Bypass -File .\access_rstudio_gui.ps1 -STA`

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

# === Configuration ===
# $remoteHosts   = @("localhost", "php_workstation@10.162.192.90") # SSH user@host
# $rstudioImages = @("rstudio-impact", "rocker/rstudio") # List your images here

#----------------------------------------------#
#   STEP 1: PROMPT FOR USERNAME AND PASSWORD   #
#----------------------------------------------#

Write-Host ""
Write-Host "================================================"
Write-Host "  IMPACT NCD Germany - Docker Container Manager"
Write-Host "================================================"
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
    
    # Display public key to user
    $publicKey = Get-Content $sshPublicKeyPath
    
    # Show message box with public key
    $message = "Your SSH public key has been generated/found.`n`n" +
               "Please copy the key below and add it to your GitHub account:`n" +
               "GitHub -> Settings -> SSH and GPG keys -> New SSH key`n`n" +
               "Public Key:`n$publicKey`n`n" +
               "The key has also been copied to your clipboard."
    
    # Copy to clipboard
    try {
        $publicKey | Set-Clipboard
        Write-Host "[SUCCESS] Public key copied to clipboard!"
    } catch {
        Write-Host "[WARNING] Could not copy to clipboard, but key is displayed above."
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
    $remoteHost = "php_workstation@10.162.192.90"  # Update this to your actual remote host
    
    # Test SSH connection with detailed feedback
    try {
        Write-Host "  Attempting connection to: $remoteHost"
        Write-Host ""
        
        # Test basic SSH connectivity
        $sshTestResult = & ssh -o ConnectTimeout=10 -o BatchMode=yes $remoteHost "echo 'SSH connection successful'" 2>&1
        
        $SSHEXITCODE = $LASTEXITCODE

        if ($SSHEXITCODE -eq 0){
            Write-Host "[SUCCESS] SSH connection established!"
            Write-Host "  Response: $sshTestResult"
            Write-Host "  Remote workstation is reachable"
            Write-Host ""

            # Extract IP address from remote host string
            $remoteIP = if ($remoteHost -match "@(.+)$") { $matches[1] } else { $remoteHost }
                
            # Set dialog result and close with success
            $script:REMOTE_HOST_IP = $remoteIP
            
        } else {
            Write-Host ""
            Write-Host "[ERROR] SSH connection failed"
            Write-Host "  Target: $remoteHost"
            Write-Host ""
            Write-Host "Please verify:"
            Write-Host "  - Network connectivity is available"
            Write-Host "  - SSH key is added to remote host authorized_keys"
            Write-Host "  - Remote host IP address is correct"
            Write-Host "  - SSH service is running on remote host"
            Write-Host ""
        
            [System.Windows.Forms.MessageBox]::Show("SSH connection to remote workstation failed.`n`nPlease check network connectivity and SSH configuration.`nSee terminal for detailed error information.", "Remote Connection Error", "OK", "Error")
            return
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
    $remoteRepoPath = "/home/php_workstation/models"  # TODO: Update this path as needed
    #$remoteHost = "php_workstation@$($script:REMOTE_HOST_IP)" TODO: CHECK IF NEEDED
    
    try {
        # Scan for subdirectories on remote host
        Write-Host "    Scanning directory: $remoteRepoPath"
        Write-Host ""
        
        $scanCommand = "find '$remoteRepoPath' -maxdepth 1 -type d -not -path '$remoteRepoPath' -exec basename {} \;"
        $availableFolders = & ssh -o ConnectTimeout=10 $remoteHost $scanCommand 2>&1
        
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
        $gitCheckCommand = "test -d '$remoteRepoPath/$($script:SELECTED_REPO)/.git' && echo 'Git repository found' || echo 'No Git repository'"
        $gitCheckResult = & ssh -o ConnectTimeout=10 $remoteHost $gitCheckCommand 2>&1
        
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
    
    # --- Create/use a REMOTE Docker context over SSH ---
    # Requires SSH access to a host that already has a Docker Engine running.
    # Replace the user/IP to match your environment.
    # Uses a TEST-NET IP reserved for documentation as a placeholder.

    $RemoteContextName  = "php_workstation"  # Name for the Docker context

    # Optional: if you need a specific key or SSH options, configure your ~/.ssh/config
    # or ensure an agent is running (ssh-agent / Pageant). Docker CLI uses your SSH setup.

    # Check if the context already exists
    $existing = & docker context ls --format '{{.Name}}' 2>$null
    $exists = $existing -contains $RemoteContextName

    if (-not $exists) {
        Write-Host "Creating Docker context '$RemoteContextName' for ssh://$remoteHost ..."
        & docker context create $RemoteContextName `
            --description "Remote engine over SSH" `
            --docker "host=ssh://$remoteHost"
    } else {
        Write-Host "Context '$RemoteContextName' already exists."
    }

    # Switch to the remote context globally
    Write-Host "Switching to context '$RemoteContextName' ..."
    & docker context use $RemoteContextName

    # Smoke test: prints Docker version from the remote host
    Write-Host "Testing remote connection with 'docker version' on '$RemoteContextName' ..."
    & docker --context $RemoteContextName version

    Write-Host "[SUCCESS] Remote Docker environment is set up and ready to use!"
    Write-Host "==================================="

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
