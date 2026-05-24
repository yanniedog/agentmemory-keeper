<#
.SYNOPSIS
  Remove agentmemory-keeper scheduled tasks and stop any running keeper.
  Leaves agentmemory itself alone.
#>
[CmdletBinding()]
param(
    [string]$TaskNameKeeper   = 'AgentmemoryKeeper',
    [string]$TaskNameWatchdog = 'AgentmemoryKeeperWatchdog',
    [switch]$KeepLogs
)

$ErrorActionPreference = 'Continue'

foreach ($name in @($TaskNameKeeper, $TaskNameWatchdog)) {
    try {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop
        Write-Host "Removed task: $name"
    } catch {
        Write-Host "Task not present: $name"
    }
}

# Kill any running keeper daemon.
$hits = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'keeper\.ps1' -and $_.CommandLine -match '-Daemon' }
foreach ($p in $hits) {
    try {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
        Write-Host "Killed keeper pid=$($p.ProcessId)"
    } catch {}
}

if (-not $KeepLogs) {
    $cfg = Get-Content -Raw (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json') | ConvertFrom-Json
    $LogDir = [System.Environment]::ExpandEnvironmentVariables($cfg.logDir)
    if (Test-Path $LogDir) {
        Write-Host "Logs preserved at: $LogDir (rerun with no flag to keep; -KeepLogs is on by default)"
    }
}

Write-Host "Uninstalled. agentmemory daemon itself was NOT touched." -ForegroundColor Green
