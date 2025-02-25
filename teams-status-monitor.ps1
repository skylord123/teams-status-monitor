<#
.SYNOPSIS
    Monitors Microsoft Teams status, call activity (including mute state), PC lock state, and display power state,
    then sends updates to a specified endpoint whenever any of these values change or after a configurable interval.

.DESCRIPTION
    This script continuously monitors:
      - The Teams client (via its log files) for availability, call activity, and mute state.
      - The workstation lock state (using a heuristic based on the presence of LogonUI.exe).
      - The display power state (using a heuristic: if locked or idle time exceeds a threshold, assume off).
    It then POSTs a JSON payload to a Node-RED endpoint whenever any monitored value changes or after a specified interval.

.NOTES
    Requires PowerShell 3.0 or higher.
#>

#region Dot Source Settings
# Ensure the settings file (settings.ps1) is in the same directory as this script.
. "$PSScriptRoot\settings.ps1"
#endregion

#region Function: Write-DebugInfo
function Write-DebugInfo {
    param([string]$Message)
    if ($DebugMode) {
        Write-Host "[DEBUG] $Message" -ForegroundColor Yellow
    }
}
#endregion

#region Global Variables
# This will store the full status object from the previous check
$CurrentFullStatus = $null
# Track the timestamp of the last sent update
$LastUpdateTime = Get-Date
#endregion

#region Add-Type for Idle Time (only add if not already defined)
if (-not ([System.Management.Automation.PSTypeName]'LASTINPUTINFO').Type) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
}
public static class Win32Idle {
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
}
"@
} else {
    Write-DebugInfo "Type LASTINPUTINFO already exists; skipping Add-Type."
}
#endregion

#region Function: Get-IdleTime
function Get-IdleTime {
    # Returns the idle time (in milliseconds) since the last input.
    $info = New-Object LASTINPUTINFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
    try {
        [void][Win32Idle]::GetLastInputInfo([ref]$info)
        $idleMs = [Environment]::TickCount - $info.dwTime
        Write-DebugInfo "System idle for $idleMs ms."
        return $idleMs
    }
    catch {
        Write-DebugInfo "Error in GetLastInputInfo: $_"
        return 0
    }
}
#endregion

#region Function: Get-WorkstationLockStatus
function Get-WorkstationLockStatus {
    # Heuristic: if LogonUI.exe is running, assume the workstation is locked.
    $logonUI = Get-Process -Name "LogonUI" -ErrorAction SilentlyContinue
    if ($logonUI) {
         Write-DebugInfo "LogonUI process detected. Workstation is locked."
         return $true
    }
    else {
         Write-DebugInfo "No LogonUI process detected. Workstation is unlocked."
         return $false
    }
}
#endregion

#region Function: Get-DisplayOnStatus
function Get-DisplayOnStatus {
    # Heuristic:
    # If the workstation is locked, assume the display is off.
    # Otherwise, if the system idle time exceeds the threshold, assume the display is off.
    $isLocked = Get-WorkstationLockStatus
    if ($isLocked) {
         Write-DebugInfo "Workstation locked -> display is off."
         return $false
    }
    $idleMs = Get-IdleTime
    if ($idleMs -ge ($MonitorOffIdleThresholdSeconds * 1000)) {
         Write-DebugInfo "Idle time ($idleMs ms) exceeds threshold -> display is off."
         return $false
    } else {
         Write-DebugInfo "Idle time below threshold -> display is on."
         return $true
    }
}
#endregion

#region Function: Get-TeamsStatusAndActivity
function Get-TeamsStatusAndActivity {
    Write-DebugInfo "Checking for Teams process among: $($TeamsProcessNameList -join ', ')"
    $teamsProcess = $null
    foreach ($name in $TeamsProcessNameList) {
        $proc = Get-Process -Name $name -ErrorAction SilentlyContinue
        if ($proc) {
            Write-DebugInfo "Process '$name' detected."
            $teamsProcess = $proc
            break
        }
    }
    if (-not $teamsProcess) {
        Write-DebugInfo "No Teams process found. Returning Offline status."
        return @{ teams_status = "Offline"; call_status = "Not In A Call"; mute_status = $false }
    }

    if (-not (Test-Path $TeamsLogFolder)) {
        Write-DebugInfo "Teams log folder '$TeamsLogFolder' does not exist."
        return @{ teams_status = "Unknown"; call_status = "Unknown"; mute_status = $false }
    }
    else {
        Write-DebugInfo "Teams log folder found: $TeamsLogFolder"
    }

    $latestLogFile = Get-ChildItem -Path $TeamsLogFolder -Filter $TeamsLogFilePattern |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $latestLogFile) {
        Write-DebugInfo "No log files matching pattern '$TeamsLogFilePattern' in '$TeamsLogFolder'."
        return @{ teams_status = "Unknown"; call_status = "Unknown"; mute_status = $false }
    }
    else {
        Write-DebugInfo "Latest log file detected: $($latestLogFile.FullName)"
    }

    try {
        # Define patterns for the various log row formats that include status information.
        $patterns = @(
            "ShowBadge New Badge:",
            "SetBadge Setting badge:",
            "SetBadge PreSetBadge verification:",
            "SetTaskbarIconOverlay"
        )

        # Search the entire file for any of these patterns (and containing "status")
        $statusLine = Select-String -Path $latestLogFile.FullName -Pattern $patterns |
                      Where-Object { $_.Line -match "status" } |
                      Select-Object -Last 1

        if ($null -eq $statusLine) {
            Write-DebugInfo "No status line found in log. teams_status='Unknown'."
            $teams_status = "Unknown"
        }
        else {
            $lineText = $statusLine.Line
            Write-DebugInfo "Status line from log: '$lineText'"
            if     ($lineText -match "(?i)available")    { $teams_status = "Available" }
            elseif ($lineText -match "(?i)busy")         { $teams_status = "Busy" }
            elseif ($lineText -match "(?i)away")         { $teams_status = "Away" }
            elseif ($lineText -match "(?i)do not disturb" -or
                    $lineText -match "(?i)donotdisturb"  -or
                    $lineText -match "(?i)donotdistrb")  { $teams_status = "Do Not Disturb" }
            else {
                Write-DebugInfo "Status line did not match known states. Setting to 'Unknown'."
                $teams_status = "Unknown"
            }
        }

        # Extract a line that indicates call activity.
        $activityLine = Select-String -Path $latestLogFile.FullName -Pattern "NotifyCallActive", "NotifyCallAccepted", "NotifyCallEnded" | Select-Object -Last 1
        if ($null -eq $activityLine) {
            Write-DebugInfo "No activity line found. call_status='Not In A Call'."
            $call_status = "Not In A Call"
        }
        else {
            $activityText = $activityLine.Line
            Write-DebugInfo "Activity line from log: '$activityText'"
            if     ($activityText -match "(?i)NotifyCallActive" -or $activityText -match "(?i)NotifyCallAccepted") {
                $call_status = "In A Call"
            }
            elseif ($activityText -match "(?i)NotifyCallEnded") {
                $call_status = "Not In A Call"
            }
            else {
                Write-DebugInfo "No recognized pattern in activity line. Setting call_status to 'Unknown'."
                $call_status = "Unknown"
            }
        }

        # Determine mute_status:
        # If not in a call, force mute_status to false.
        if ($call_status -ne "In A Call") {
            $mute_status = $false
            Write-DebugInfo "Not in a call. Forcing mute_status to false."
        }
        else {
            # Extract the latest mute state change that includes the mute state
            $muteLine = Select-String -Path $latestLogFile.FullName -Pattern "reportMuteStateChange.*mute state:" | Select-Object -Last 1
            if ($muteLine) {
                if ($muteLine.Line -match "mute state:(?<muteState>true|false)") {
                    $mute_status = ($Matches["muteState"] -eq "true")
                }
                else {
                    $mute_status = $false
                }
                Write-DebugInfo "Mute state determined from log: $mute_status"
            }
            else {
                Write-DebugInfo "No mute state line found. Setting mute_status to false."
                $mute_status = $false
            }

        }
    }
    catch {
        Write-DebugInfo "Error reading log file: $_"
        return @{ teams_status = "Unknown"; call_status = "Unknown"; mute_status = $false }
    }

    return @{ teams_status = $teams_status; call_status = $call_status; mute_status = $mute_status }
}
#endregion

#region Function: Get-FullStatus
function Get-FullStatus {
    $teamsObj = Get-TeamsStatusAndActivity
    $locked   = Get-WorkstationLockStatus
    $display  = Get-DisplayOnStatus
    return @{
        teams_status = $teamsObj.teams_status
        call_status  = $teamsObj.call_status
        mute_status  = $teamsObj.mute_status
        pc_locked    = $locked
        display_on   = $display
    }
}
#endregion

#region Function: Send-FullStatus
function Send-FullStatus {
    param (
        [string]$teams_status,
        [string]$call_status,
        [bool]$mute_status,
        [bool]$pc_locked,
        [bool]$display_on
    )

    $in_call = $false
    if ($call_status -eq "In A Call") { $in_call = $true }

    $payload = @{
        teams_status = $teams_status
        call_status  = $call_status
        mute_status  = $mute_status
        in_call      = $in_call
        pc_locked    = $pc_locked
        display_on   = $display_on
        timestamp    = (Get-Date).ToString("o")
    } | ConvertTo-Json

    $headers = @{}
    if ($Token -and $Token.Length -gt 0) {
        $headers["Authorization"] = $Token
    }

    try {
        Invoke-RestMethod -Uri $EndpointUrl -Method Post -Body $payload -ContentType "application/json" -Headers $headers
        Write-Host "Sent update: teams_status='$teams_status', call_status='$call_status', mute_status=$mute_status, pc_locked=$pc_locked, display_on=$display_on"
    }
    catch {
        Write-Error "Failed to send update: $_"
    }
}
#endregion

#region Main Loop
# Get and send the initial full status.
$CurrentFullStatus = Get-FullStatus
Send-FullStatus -teams_status $CurrentFullStatus.teams_status `
                -call_status $CurrentFullStatus.call_status `
                -mute_status $CurrentFullStatus.mute_status `
                -pc_locked $CurrentFullStatus.pc_locked `
                -display_on $CurrentFullStatus.display_on
$LastUpdateTime = Get-Date

# Continuously monitor for any changes.
while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds
    $newStatus = Get-FullStatus
    $statusChanged = ($newStatus.teams_status -ne $CurrentFullStatus.teams_status) -or
                     ($newStatus.call_status  -ne $CurrentFullStatus.call_status)  -or
                     ($newStatus.mute_status  -ne $CurrentFullStatus.mute_status)  -or
                     ($newStatus.pc_locked    -ne $CurrentFullStatus.pc_locked)    -or
                     ($newStatus.display_on   -ne $CurrentFullStatus.display_on)

    $now = Get-Date
    $forceUpdate = ($ForceUpdateIntervalSeconds -gt 0) -and ( ($now - $LastUpdateTime).TotalSeconds -ge $ForceUpdateIntervalSeconds )

    if ($statusChanged -or $forceUpdate) {
        $CurrentFullStatus = $newStatus
        Send-FullStatus -teams_status $CurrentFullStatus.teams_status `
                        -call_status $CurrentFullStatus.call_status `
                        -mute_status $CurrentFullStatus.mute_status `
                        -pc_locked $CurrentFullStatus.pc_locked `
                        -display_on $CurrentFullStatus.display_on
        $LastUpdateTime = $now
    }
}
#endregion
