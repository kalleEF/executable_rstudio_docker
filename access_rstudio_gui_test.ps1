
# === Configuration ===
$remoteHost   = "localhost"   # SSH user@host


# Button click event handler
$student = "karl"
$password = "test1234"
$container = "rstudio-$student"
$rstudioImage = "rstudio-impact"

# Escape password for shell
$escapedPass = $password -replace "'", "'\\''"

# Build remote SSH script
$remoteScript = @"
# Check if container exists
$containerExists = docker container inspect '$container'
if (`$LASTEXITCODE -eq 1) {
    docker run -d --name '$container' -e PASSWORD='$escapedPass' -p 0:8787 '$rstudioImage' | Out-Null
} else {
    docker start '$container' | Out-Null
}
# Wait for the container to be running
$tryCount = 0
while ((docker inspect -f '{{.State.Running}}' '$container') -ne 'true' -and '$tryCount' -lt 10) {
    Start-Sleep -Seconds 1
    $tryCount++
}
# Get mapped port for 8787
$portInfo = docker port '$container' 8787
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
"@

# Connect to remote host and run the script
$bytes = [System.Text.Encoding]::Unicode.GetBytes($remoteScript)
$encodedScript = [Convert]::ToBase64String($bytes)
$sshCommand = "PowerShell -NoProfile -EncodedCommand $encodedScript"

# For local testing:
$localScript = $remoteScript
$bytes = [System.Text.Encoding]::Unicode.GetBytes($localScript)
$encodedScript = [Convert]::ToBase64String($bytes)
$sshOutput = PowerShell -NoProfile -EncodedCommand $encodedScript 2>&1

Write-Host $sshOutput

Invoke-Expression $sshCommand
# For deployment:
#$sshOutput = ssh $remoteHost $sshCommand 2>&1


### Testing ps1 without compilation:
#  PowerShell -ExecutionPolicy Bypass -File .\access_rstudio_gui.ps1 -STA

### Testing with compilation:
#  PS2EXE -InputFile .\access_rstudio_gui.ps1 -OutputFile .\Rstudio_Docker.exe
