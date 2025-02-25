# Ensure the script is run as Administrator
$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Restarting script as Administrator..."
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# Define service properties
$ServiceName = "TeamsStatusMonitorService"
$DisplayName = "Teams Status Monitor Service"

# Define NSSM paths
$NssmZipUrl = "https://nssm.cc/release/nssm-2.24.zip"
$NssmZipPath = Join-Path $PSScriptRoot "nssm.zip"
$NssmExtractPath = Join-Path $PSScriptRoot "nssm-2.24"
$NssmPath = Join-Path $PSScriptRoot "nssm.exe"

# Download and extract NSSM if missing
if (-not (Test-Path $NssmPath)) {
    Write-Host "nssm.exe not found. Downloading from $NssmZipUrl..."

    try {
        Invoke-WebRequest -Uri $NssmZipUrl -OutFile $NssmZipPath
        Write-Host "Download complete. Extracting..."

        # Extract NSSM
        Expand-Archive -Path $NssmZipPath -DestinationPath $PSScriptRoot -Force

        # Move the NSSM executable to the script directory
        Move-Item -Path "$NssmExtractPath\win64\nssm.exe" -Destination $PSScriptRoot -Force

        # Cleanup extracted folder and zip
        Remove-Item -Path $NssmZipPath -Force
        Remove-Item -Path $NssmExtractPath -Recurse -Force
        Write-Host "NSSM installation complete."
    } catch {
        Write-Error "Failed to download or extract NSSM: $_"
        exit 1
    }
}

# Determine the full path to teams-status-monitor.ps1
$ScriptPath = Join-Path $PSScriptRoot "teams-status-monitor.ps1"

# Get the full path to PowerShell.exe
$PowerShellExe = (Get-Command powershell.exe).Source

# Build the arguments for PowerShell:
$Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

Write-Host "Installing/updating service '$ServiceName' using NSSM..."

# Check if the service exists
$serviceExists = $false
try {
    $serviceStatusOutput = & $NssmPath status $ServiceName 2>&1
    if ($serviceStatusOutput -notmatch "Can't open service!") {
        $serviceExists = $true
        Write-Host "Service '$ServiceName' exists. It will be updated." -ForegroundColor Green
    }
    else {
        Write-Host "Service '$ServiceName' does not exist." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Service '$ServiceName' does not exist." -ForegroundColor Yellow
}

if ($serviceExists) {
    Write-Host "Updating service configuration..."
    & $NssmPath set $ServiceName Application $PowerShellExe
    & $NssmPath set $ServiceName AppParameters $Arguments
} else {
    Write-Host "Creating new service '$ServiceName'..."
    & $NssmPath install $ServiceName $PowerShellExe $Arguments
}

# Set the display name and startup type
& $NssmPath set $ServiceName DisplayName $DisplayName
& $NssmPath set $ServiceName Start SERVICE_AUTO_START

Write-Host "Service '$ServiceName' has been installed/updated."

# Attempt to start the service
try {
    Start-Service -Name $ServiceName
    Write-Host "Service '$ServiceName' started successfully." -ForegroundColor Green
} catch {
    Write-Warning "Failed to start service '$ServiceName'. You may need to start it manually."
}
