<#
 PowerShell GUI Launcher for RStudio Containers
 ---------------------------------------------
 This script prompts for username and password, then connects over SSH
 to start or create a Docker container, returning the URL for RStudio.

 Usage (uncompiled .ps1):
  - Open PowerShell console (not by double-clicking)
  - cd to script folder
  - Run: `PowerShell -ExecutionPolicy Bypass -File .\access-rstudio-gui.ps1 -STA`

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
$remoteHost   = "youruser@remote-server.edu"   # SSH user@host
$rstudioImages = @("rstudio-impact", "rocker/rstudio") # List your images here

# Build the form
$form = New-Object System.Windows.Forms.Form -Property @{ 
    Text = 'Remote Access - IMPACT NCD Germany'; Size = New-Object System.Drawing.Size(400,240); StartPosition = 'CenterScreen' }

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

# Launch button (move down)
$button = New-Object System.Windows.Forms.Button -Property @{ Text='Launch RStudio'; Location=New-Object System.Drawing.Point(120,140); Size=New-Object System.Drawing.Size(120,30) }
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

    # Escape password for shell
    $escapedPass = $password -replace "'", "'\\''"

    # Build remote SSH script
    $remoteScript = @"
if ! docker ps -a --format '{{.Names}}' | grep -qx \"$container\"; then
  docker run -d --name $container -e PASSWORD=\"$escapedPass\" -p 0:8787 $rstudioImage > /dev/null
else
  docker start $container > /dev/null
fi
# report host port
docker port $container 8787 | sed 's/.*://'
"@

    # Test SSH connection with visual indicator
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

    # Connect to remote host and run the script
    try {
        $sshOutput = ssh $remoteHost $remoteScript 2>&1
        # Ensure $sshOutput is a string
        if ($sshOutput -isnot [string]) {
            $sshOutput = $sshOutput | Out-String
        }
        $port = $sshOutput.Trim() -split "`r?`n" | Select-Object -Last 1
        if (-not $port -or $port -notmatch '^\d+$') {
            throw "Failed to get port from remote. SSH output:`n$sshOutput"
        }
        $hostIP = $remoteHost.Split('@')[1]
        [System.Windows.Forms.MessageBox]::Show("RStudio is ready!`nURL: http://$hostIP`:$port`nUsername: rstudio`nPassword: $password", 'Success','OK','Information')
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
