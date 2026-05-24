<#
.SYNOPSIS
  Agentmemory Keeper control CLI.

.EXAMPLE
  .\ctl.ps1 status          # show keeper + daemon health
  .\ctl.ps1 restart         # force a full reclamation + restart
  .\ctl.ps1 reclaim         # kill stuck processes / clear ports, do not restart
  .\ctl.ps1 doctor          # diagnostic dump (config, ports, processes, recent log)
  .\ctl.ps1 logs            # tail today's keeper log
  .\ctl.ps1 daemon-start    # start keeper in this window (foreground)
  .\ctl.ps1 stop            # stop daemon and keeper task
  .\ctl.ps1 install         # install scheduled tasks (no admin required)
  .\ctl.ps1 uninstall       # remove scheduled tasks
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status','restart','reclaim','doctor','logs','daemon-start','stop','install','uninstall','ingest','savings','help')]
    [string]$Command = 'status',

    [int]$Lines = 80
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Keeper     = Join-Path $ScriptRoot 'keeper.ps1'
$ConfigPath = Join-Path $ScriptRoot 'config.json'
$Installer  = Join-Path $ScriptRoot 'install.ps1'
$Uninstaller= Join-Path $ScriptRoot 'uninstall.ps1'

$cfg = Get-Content -Raw $ConfigPath | ConvertFrom-Json
$LogDir   = [System.Environment]::ExpandEnvironmentVariables($cfg.logDir)
$StateDir = [System.Environment]::ExpandEnvironmentVariables($cfg.stateDir)
$AmDir    = [System.Environment]::ExpandEnvironmentVariables($cfg.agentmemoryConfigDir)

function Format-Section($title) {
    Write-Host ''
    Write-Host ('== ' + $title + ' ' + ('=' * (60 - $title.Length))) -ForegroundColor Cyan
}

function Get-DaemonHealth {
    $paths = @('/api/v1/health','/health','/status','/')
    foreach ($p in $paths) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$($cfg.restPort)$p")
            $req.Timeout = 3000
            $req.KeepAlive = $false
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return [pscustomobject]@{ Healthy = $true; Path = $p; Code = $code }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
                $_.Exception.Response.Close()
                return [pscustomobject]@{ Healthy = $true; Path = $p; Code = $code }
            }
        } catch {}
    }
    return [pscustomobject]@{ Healthy = $false; Path = $null; Code = 0 }
}

function Get-KeeperProcess {
    $hits = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'keeper\.ps1' -and $_.CommandLine -match '-Daemon' }
    return $hits
}

function Get-LogPath {
    Join-Path $LogDir ("keeper-" + (Get-Date -Format 'yyyy-MM-dd') + '.log')
}

function Show-Status {
    Format-Section "Daemon (agentmemory)"
    $h = Get-DaemonHealth
    if ($h.Healthy) {
        Write-Host ("  agentmemory: healthy ({0} -> {1})" -f $h.Path, $h.Code) -ForegroundColor Green
    } else {
        Write-Host "  agentmemory: NOT RESPONDING on 127.0.0.1:$($cfg.restPort)" -ForegroundColor Red
    }

    Format-Section "Keeper"
    $procs = @(Get-KeeperProcess)
    if ($procs.Count -gt 0) {
        foreach ($p in $procs) {
            Write-Host ("  keeper: pid={0} started={1}" -f $p.ProcessId, $p.CreationDate) -ForegroundColor Green
        }
    } else {
        Write-Host "  keeper: not running" -ForegroundColor Yellow
    }

    Format-Section "Ports"
    $ports = @($cfg.restPort, $cfg.streamsPort, $cfg.viewerPort, $cfg.viewerFallbackPort, $cfg.enginePort)
    foreach ($port in $ports) {
        $listen = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        if ($listen) {
            $pidVal = $listen[0].OwningProcess
            $pname = ''
            try { $pname = (Get-Process -Id $pidVal -ErrorAction Stop).ProcessName } catch {}
            Write-Host ("  :{0,-6}  listen by pid {1} ({2})" -f $port, $pidVal, $pname)
        } else {
            Write-Host ("  :{0,-6}  free" -f $port) -ForegroundColor DarkGray
        }
    }

    Format-Section "Scheduled tasks"
    foreach ($name in @('AgentmemoryKeeper','AgentmemoryKeeperWatchdog')) {
        $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        if ($t) {
            $info = Get-ScheduledTaskInfo -TaskName $name
            Write-Host ("  {0,-30} state={1} lastRun={2} lastResult={3}" -f $name, $t.State, $info.LastRunTime, $info.LastTaskResult)
        } else {
            Write-Host ("  {0,-30} not installed" -f $name) -ForegroundColor Yellow
        }
    }

    $statePath = Join-Path $StateDir 'keeper-state.json'
    if (Test-Path $statePath) {
        Format-Section "Last events"
        $s = Get-Content -Raw $statePath | ConvertFrom-Json
        $recent = @($s.restartHistory | Sort-Object -Descending | Select-Object -First 5)
        Write-Host ("  lastHealthyAt: {0}" -f $s.lastHealthyAt)
        Write-Host ("  restarts last hour: {0}" -f @($s.restartHistory | Where-Object { $_ -and ([datetime]$_) -gt (Get-Date).AddHours(-1) }).Count)
        if ($recent.Count -gt 0) {
            Write-Host "  recent restarts:"
            foreach ($r in $recent) { Write-Host ("    - {0}" -f $r) }
        }
    }
    Write-Host ''
}

function Invoke-Restart {
    Write-Host "Forcing restart..." -ForegroundColor Yellow
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Keeper -Once
    Start-Sleep -Seconds 2
    Show-Status
}

function Invoke-Reclaim {
    Write-Host "Reclaiming ports / killing stale processes (no restart)..." -ForegroundColor Yellow
    $ports = @($cfg.restPort, $cfg.streamsPort, $cfg.viewerPort, $cfg.viewerFallbackPort, $cfg.enginePort)
    foreach ($port in $ports) {
        $conns = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            $procId = $c.OwningProcess
            if ($procId -and $procId -ne 0) {
                try {
                    $proc = Get-Process -Id $procId -ErrorAction Stop
                    Write-Host ("  killing pid={0} name={1} on port {2}" -f $procId, $proc.ProcessName, $port)
                    Stop-Process -Id $procId -Force -ErrorAction Stop
                } catch {
                    Write-Host ("  failed to kill pid={0}: {1}" -f $procId, $_.Exception.Message) -ForegroundColor Red
                }
            }
        }
    }
    Get-Process -Name 'iii' -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host ("  killing orphan iii pid={0}" -f $_.Id)
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    foreach ($f in @((Join-Path $AmDir 'iii.pid'), (Join-Path $AmDir 'engine-state.json'))) {
        if (Test-Path $f) {
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            Write-Host ("  removed {0}" -f $f)
        }
    }
    Write-Host "Done." -ForegroundColor Green
}

function Show-Doctor {
    Show-Status
    Format-Section "Configuration"
    Get-Content $ConfigPath | Write-Host

    Format-Section "agentmemory CLI location"
    $shim = Join-Path $env:APPDATA 'npm\agentmemory.cmd'
    if (Test-Path $shim) {
        Write-Host "  $shim"
    } else {
        Write-Host "  not found (npm i -g @agentmemory/agentmemory)" -ForegroundColor Yellow
    }

    Format-Section "agentmemory home"
    if (Test-Path $AmDir) {
        Get-ChildItem $AmDir -Force | Select-Object Mode, LastWriteTime, Length, Name | Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "  $AmDir not present" -ForegroundColor Yellow
    }

    Format-Section "Recent keeper log (last $Lines lines)"
    $log = Get-LogPath
    if (Test-Path $log) {
        Get-Content $log -Tail $Lines | Write-Host
    } else {
        Write-Host "  no log yet at $log" -ForegroundColor DarkGray
    }
}

function Show-Logs {
    $log = Get-LogPath
    if (-not (Test-Path $log)) {
        Write-Host "No log file yet at $log" -ForegroundColor Yellow
        return
    }
    Get-Content $log -Tail $Lines -Wait
}

function Start-DaemonForeground {
    Write-Host "Starting keeper in foreground (Ctrl+C to stop)..." -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Keeper -Daemon
}

function Stop-All {
    Write-Host "Stopping keeper task and daemon..." -ForegroundColor Yellow
    try { Stop-ScheduledTask -TaskName 'AgentmemoryKeeper' -ErrorAction SilentlyContinue } catch {}
    foreach ($p in (Get-KeeperProcess)) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Host "  killed keeper pid=$($p.ProcessId)" } catch {}
    }
    $shim = Join-Path $env:APPDATA 'npm\agentmemory.cmd'
    if (Test-Path $shim) {
        & $shim stop --force 2>&1 | Out-Host
    }
    Invoke-Reclaim
}

function Show-Savings {
    try {
        $resp = Invoke-WebRequest "http://127.0.0.1:$($cfg.restPort)/agentmemory/sessions" -UseBasicParsing -TimeoutSec 10
        $d = $resp.Content | ConvertFrom-Json
        $sArr = $d.sessions
        $obs = ($sArr | Measure-Object observationCount -Sum).Sum
        $estFull = $obs * 80
        $estInjected = $sArr.Count * 2000
        $pct = if ($estFull -gt 0) { [Math]::Round((1 - $estInjected / $estFull) * 100, 1) } else { 0 }
        $saved = [Math]::Max(0, $estFull - $estInjected)
        $cost = [Math]::Round($saved / 1000 * 0.30, 2)
        Format-Section "Token Savings"
        Write-Host ("  sessions     : {0}" -f $sArr.Count)
        Write-Host ("  observations : {0:N0}" -f ([int]$obs))
        Write-Host ""
        Write-Host ("  Savings      : {0}%" -f $pct) -ForegroundColor Green
        Write-Host ("  Tokens saved : {0:N0}" -f $saved) -ForegroundColor Green
        Write-Host ("  ~Cost saved  : `${0:N2}" -f $cost) -ForegroundColor Green
        Write-Host ""
        Write-Host "  Live: http://127.0.0.1:$($cfg.viewerPort)/"
    } catch {
        Write-Host "agentmemory not responding: $($_.Exception.Message)" -ForegroundColor Red
    }
}

switch ($Command) {
    'status'        { Show-Status }
    'restart'       { Invoke-Restart }
    'reclaim'       { Invoke-Reclaim }
    'doctor'        { Show-Doctor }
    'logs'          { Show-Logs }
    'daemon-start'  { Start-DaemonForeground }
    'stop'          { Stop-All }
    'install'       { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Installer }
    'uninstall'     { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Uninstaller }
    'ingest'        { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptRoot 'ingest.ps1') }
    'savings'       { Show-Savings }
    'help'          { Get-Help $PSCommandPath -Detailed }
    default         { Show-Status }
}
