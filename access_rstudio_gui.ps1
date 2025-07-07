<#
 PowerShell GUI Launcher for RStudio Containers
 ---------------------------------------------
 This script prompts for username and password, then connects over SSH
 to start or create a Docker container, returning the URL for RStudio.

 Usage (uncompiled .ps1):
  - Open PowerShell console (not by double-clicking)
  - cd to script folder
  - Run: `PowerShell -ExecutionPolicy Bypass -File .\access_rstudio_gui.ps1 -STA`

 To make it double-clickable:
 1. Install ps2exe (if needed):
      Install-Module -Name ps2exe -Scope CurrentUser
 2. Compile to exe:
      Invoke-PS2EXE -InputFile .\access-rstudio-gui.ps1 -OutputFile .\access-rstudio-gui.exe
 3. Double-click the resulting `access-rstudio-gui.exe` to launch the GUI.
#>

# Ensure Windows Forms app environment
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# === Configuration ===
$remoteHosts   = @("localhost", "php_workstation@XXX.XX.XX.XX") # SSH user@host
$rstudioImages = @("rstudio-impact", "rocker/rstudio") # List your images here

# Build the form
$form = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Remote Access - IMPACT NCD Germany'; Size = New-Object System.Drawing.Size(400,260); StartPosition = 'CenterScreen' }

# Username label and textbox
$labelUser = New-Object System.Windows.Forms.Label -Property @{ Text='Username:'; Location=New-Object System.Drawing.Point(10,20); Size=New-Object System.Drawing.Size(100,20) }
$form.Controls.Add($labelUser)
$textUser = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(120,20); Size=New-Object System.Drawing.Size(250,20) }
$form.Controls.Add($textUser)

# Password label and textbox
$labelPass = New-Object System.Windows.Forms.Label -Property @{ Text='RStudio Password:'; Location=New-Object System.Drawing.Point(10,60); Size=New-Object System.Drawing.Size(100,20) }
$form.Controls.Add($labelPass)
$textPass = New-Object System.Windows.Forms.TextBox -Property @{ Location=New-Object System.Drawing.Point(120,60); Size=New-Object System.Drawing.Size(250,20); UseSystemPasswordChar=$true }
$form.Controls.Add($textPass)

# RStudio Image label and combobox
$labelImage = New-Object System.Windows.Forms.Label -Property @{ Text='RStudio Image:'; Location=New-Object System.Drawing.Point(10,100); Size=New-Object System.Drawing.Size(100,20) }
$form.Controls.Add($labelImage)
$comboImage = New-Object System.Windows.Forms.ComboBox -Property @{ Location=New-Object System.Drawing.Point(120,100); Size=New-Object System.Drawing.Size(250,20); DropDownStyle = 'DropDownList' }
$comboImage.Items.AddRange($rstudioImages)
$comboImage.SelectedIndex = 0
$form.Controls.Add($comboImage)

# Host label and combobox
$labelHost = New-Object System.Windows.Forms.Label -Property @{ Text='Host:'; Location=New-Object System.Drawing.Point(10,140); Size=New-Object System.Drawing.Size(100,20) }
$form.Controls.Add($labelHost)
$comboHost = New-Object System.Windows.Forms.ComboBox -Property @{ Location=New-Object System.Drawing.Point(120,140); Size=New-Object System.Drawing.Size(250,20); DropDownStyle = 'DropDownList' }
$comboHost.Items.AddRange($remoteHosts)
$comboHost.SelectedIndex = 0
$form.Controls.Add($comboHost)

# Launch button (move down)
$button = New-Object System.Windows.Forms.Button -Property @{ Text='Launch Container'; Location=New-Object System.Drawing.Point(120,180); Size=New-Object System.Drawing.Size(120,30) }
$form.Controls.Add($button)

# Button click event handler
$button.Add_Click({
    $student = $textUser.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($student)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a username.','Error','OK','Error')
        return
    }
    $password = $textPass.Text
    if ([string]::IsNullOrEmpty($password)) {
        [System.Windows.Forms.MessageBox]::Show('Please enter a password.','Error','OK','Error')
        return
    }
    $container = "rstudio-$student"
    $rstudioImage = $comboImage.SelectedItem
    $remoteHost = $comboHost.SelectedItem

    # Escape password for shell
    $escapedPass = $password -replace "'", "'\\''"

    # Build remote SSH script
    if ($remoteHost -eq 'localhost') {
        # Ensure to use local context
        docker context use desktop-linux | Out-Null
        Write-Host "Using local Docker context 'desktop-linux'."
        # For local testing, use a direct script block
        $dockerScript = @'
# Check if container exists
$containerExists = docker container inspect $container
if ($LASTEXITCODE -eq 1) {
    docker run -d --name $container -e PASSWORD=$escapedPass -p 0:8787 $rstudioImage | Out-Null
} else {
    docker start $container | Out-Null
}
# Wait for the container to be running
$tryCount = 0
while ((docker inspect -f '{{.State.Running}}' $container) -ne 'true' -and $tryCount -lt 10) {
    Start-Sleep -Seconds 1
    $tryCount++
}
# Get mapped port for 8787
$portInfo = docker port $container 8787
if (-not $portInfo) {
    Write-Error 'ERROR: Failed to determine mapped port for RStudio container.'
    exit 1
}
$port = ($portInfo -split ':')[-1].Trim()
if (-not $port -or -not ($port -match '^\d+$')) {
    Write-Error 'ERROR: Failed to determine mapped port for RStudio container.'
    exit 1
}
Write-Output $port
'@
    } else {
    # If on remote host, check, create, or use Docker context

    # Check if context exists
    $dockerContexts = docker context ls
    $targetContext = "remote-workstation"
    if ($dockerContexts -match "^\s*${targetContext}(\s|\*)") {
        Write-Host "Context '$targetContext' is available."
        $remoteContextExists = $true
    } else {
        Write-Host "Context '$targetContext' is NOT available."
        $remoteContextExists = $false
    }
    if ($remoteContextExists -eq $true) {
        # Use the remote context if it exists
        docker context use $targetContext | Out-Null
        Write-Host "Using existing context '$targetContext'."
    } else { # Create the remote context if it doesn't exist
        docker context create $targetContext --docker "host=ssh://$remoteHost" | Out-Null
        docker context use $targetContext | Out-Null
        Write-Host "Created and switched to context '$targetContext'."
    }

    $dockerScript = @'  
# Check if container exists
$containerExists = docker container inspect $container
if ($LASTEXITCODE -eq 1) {
    docker run -d --name $container -e PASSWORD=$escapedPass -p 0:8787 $rstudioImage | Out-Null
} else {
    docker start $container | Out-Null
}
# Wait for the container to be running
$tryCount = 0
while ((docker inspect -f '{{.State.Running}}' $container) -ne 'true' -and $tryCount -lt 10) {
    Start-Sleep -Seconds 1
    $tryCount++
}
# Get mapped port for 8787
$portInfo = docker port $container 8787
if (-not $portInfo) {
    Write-Error 'ERROR: Failed to determine mapped port for RStudio container.'
    exit 1
}
$port = ($portInfo -split ':')[-1].Trim()
if (-not $port -or -not ($port -match '^\d+$')) {
    Write-Error 'ERROR: Failed to determine mapped port for RStudio container.'
    exit 1
}
Write-Output $port
'@
       }
    
   # Test SSH connection with visual indicator
   if ($remoteHost -ne "localhost") {
    try {
        $form.Enabled = $false
        $oldCursor = $form.Cursor
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $job = Start-Job -ScriptBlock { param($remoteHostParam) ssh -q $remoteHostParam "echo test" } -ArgumentList $remoteHost
        $completed = $job | Wait-Job -Timeout 10
        if (-not $completed) {
            Stop-Job $job | Out-Null
            Remove-Job $job | Out-Null
            $form.Cursor = $oldCursor
            $form.Enabled = $true
            [System.Windows.Forms.MessageBox]::Show("SSH connection timed out. Please check your network or remote host.", 'Error','OK','Error')
            return
        }
        $null = Receive-Job $job
        Remove-Job $job | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $form.Cursor = $oldCursor
            $form.Enabled = $true
            [System.Windows.Forms.MessageBox]::Show("Cannot connect to remote host via SSH.", 'Error','OK','Error')
            return
        }
        $form.Cursor = $oldCursor
        $form.Enabled = $true
    } catch {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $form.Enabled = $true
        [System.Windows.Forms.MessageBox]::Show("Unexpected error during SSH connection test.`n$($_.Exception.Message)", 'Error','OK','Error')
        return
    }
   } 
   
    # Connect to remote host and run the script
    try {
        if ($remoteHost -eq 'localhost') {
            # For local testing, run the script directly
            $sshOutput = Invoke-Expression $dockerScript 2>&1
            Write-Host "-> Running locally!"
        } else {
            # For deployment, encode the script for SSH
            $sshOutput = Invoke-Expression $dockerScript 2>&1
            Write-Host "-> Running remotely over SSH using a Docker context at $remoteHost`n"
        }
        # Ensure $sshOutput is a string
        if ($sshOutput -isnot [string]) {
            $sshOutput = $sshOutput | Out-String
        }
        $port = $sshOutput.Trim() -split "`r?`n" | Select-Object -Last 1
        if (-not $port -or $port -notmatch '^\d+$') {
            throw "Failed to get port from remote. SSH output:`n$sshOutput"
        }
        if ($remoteHost -eq 'localhost') {
            [System.Windows.Forms.MessageBox]::Show("RStudio is ready!`nURL: http://$remoteHost`:$port`nUsername: rstudio`nPassword: $password", 'Success','OK','Information')
            Write-Host "-> RStudio is ready!`n-> Connect via URL: http://$remoteHost`:$port`n-> Username: rstudio`n-> Password: $password"
        } else {
            $hostIP = $remoteHost.Split('@')[1]
            [System.Windows.Forms.MessageBox]::Show("RStudio is ready!`nURL: http://$hostIP`:$port`nUsername: rstudio`nPassword: $password", 'Success','OK','Information')
            Write-Host "-> RStudio is ready!`n-> Connect via URL: http://$hostIP`:$port`n-> Username: rstudio`n-> Password: $password"
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error launching container:`n$($_.Exception.Message)", 'Error','OK','Error')
    }
})

# Show the form and keep script alive
[void]$form.ShowDialog()


### Testing ps1 without compilation:
#  PowerShell -ExecutionPolicy Bypass -File .\access_rstudio_gui.ps1 -STA

### Testing with compilation:
#  PS2EXE -InputFile .\access_rstudio_gui.ps1 -OutputFile .\Rstudio_Docker.exe
