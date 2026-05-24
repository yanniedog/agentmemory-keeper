<#
.SYNOPSIS
  Agentmemory Keeper - supervisor loop that keeps the local agentmemory daemon
  healthy across sleep/wake, network drops, VPN changes, airplane mode,
  BleachBit cache wipes, and stray ghost ports from old browser tabs.

.DESCRIPTION
  Runs as a long-lived user-mode process (started by a Scheduled Task at
  logon). Probes agentmemory health on a fast interval. When the daemon is
  unresponsive, it performs surgical reclamation:
    1. agentmemory stop --force   (best effort)
    2. Kill any process holding REST / viewer / engine ports that matches our
       own signature (iii.exe, node.exe running agentmemory cli.mjs).
    3. Remove stale pidfile / engine-state.
    4. Start agentmemory fresh, wait for /status to respond.
  Sleep / wake is detected by wall-clock skew between iterations.

.PARAMETER Daemon
  Run forever (used by the scheduled task).

.PARAMETER Once
  Run one health-check cycle and exit (used by ctl.ps1 / watchdog).

.PARAMETER ConfigPath
  Override the config.json path. Default: alongside this script.
#>

[CmdletBinding()]
param(
    [switch]$Daemon,
    [switch]$Once,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Paths & config
# ---------------------------------------------------------------------------

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'config.json' }

if (-not (Test-Path $ConfigPath)) {
    Write-Error "Config file not found: $ConfigPath"
    exit 2
}

$cfg = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

function Expand-EnvPath([string]$path) {
    [System.Environment]::ExpandEnvironmentVariables($path)
}

$LogDir            = Expand-EnvPath $cfg.logDir
$StateDir          = Expand-EnvPath $cfg.stateDir
$AgentmemoryDir    = Expand-EnvPath $cfg.agentmemoryConfigDir
$PidFile           = Join-Path $AgentmemoryDir 'iii.pid'
$EngineStateFile   = Join-Path $AgentmemoryDir 'engine-state.json'

foreach ($d in @($LogDir, $StateDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$StateFile = Join-Path $StateDir 'keeper-state.json'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$script:LogPath = Join-Path $LogDir ("keeper-" + (Get-Date -Format 'yyyy-MM-dd') + '.log')

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')] [string]$Level = 'INFO'
    )
    $today = Get-Date -Format 'yyyy-MM-dd'
    $expected = Join-Path $LogDir ("keeper-$today.log")
    if ($expected -ne $script:LogPath) { $script:LogPath = $expected }

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $Message
    try {
        Add-Content -Path $script:LogPath -Value $line -Encoding utf8 -ErrorAction Stop
    } catch {
        # If log write fails (disk full, etc.) keep going.
    }
    if (-not $Daemon -or $env:AGENTMEMORY_KEEPER_VERBOSE -eq '1') {
        Write-Host $line
    }
}

function Rotate-OldLogs {
    $keepDays = if ($cfg.PSObject.Properties.Name -contains 'logRetentionDays') { [int]$cfg.logRetentionDays } else { 14 }
    Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq '.log' -and $_.LastWriteTime -lt (Get-Date).AddDays(-$keepDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# State persistence (restart history, last seen)
# ---------------------------------------------------------------------------

function Load-State {
    if (Test-Path $StateFile) {
        try { return Get-Content -Raw $StateFile | ConvertFrom-Json } catch {}
    }
    [pscustomobject]@{
        restartHistory = @()
        lastHealthyAt  = $null
        startedAt      = (Get-Date).ToString('o')
    }
}

function Save-State($state) {
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding utf8
    } catch {
        Write-Log "Failed to persist state: $($_.Exception.Message)" WARN
    }
}

# ---------------------------------------------------------------------------
# Health probe (fast, cancellable, no node spawn)
# ---------------------------------------------------------------------------

function Test-Health {
    param([int]$TimeoutMs = 5000, [int]$Port = $cfg.restPort)
    # Probe several known endpoints. Any non-timeout response (incl. 404)
    # proves the HTTP server is alive. Timeout / connection refused = down.
    $paths = @('/api/v1/health', '/health', '/status', '/')
    foreach ($p in $paths) {
        $url = "http://127.0.0.1:$Port$p"
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Method  = 'GET'
            $req.Timeout = $TimeoutMs
            $req.ReadWriteTimeout = $TimeoutMs
            $req.AllowAutoRedirect = $false
            $req.KeepAlive = $false
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return [pscustomobject]@{ Healthy = $true; Code = $code; Path = $p; Error = $null }
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) {
                $code = [int]$_.Exception.Response.StatusCode
                $_.Exception.Response.Close()
                return [pscustomobject]@{ Healthy = $true; Code = $code; Path = $p; Error = $null }
            }
            $lastErr = $_.Exception.Message
        } catch {
            $lastErr = $_.Exception.Message
        }
    }
    return [pscustomobject]@{ Healthy = $false; Code = 0; Path = $null; Error = $lastErr }
}

# ---------------------------------------------------------------------------
# Process / port reclamation
# ---------------------------------------------------------------------------

function Get-PortHolders {
    param([int[]]$Ports)
    $holders = @{}
    foreach ($port in $Ports) {
        $conns = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue
        foreach ($c in $conns) {
            if ($null -ne $c.OwningProcess -and $c.OwningProcess -ne 0) {
                if (-not $holders.ContainsKey($c.OwningProcess)) {
                    $holders[$c.OwningProcess] = New-Object System.Collections.Generic.List[int]
                }
                if (-not $holders[$c.OwningProcess].Contains($port)) {
                    $holders[$c.OwningProcess].Add($port)
                }
            }
        }
    }
    return $holders
}

function Get-ProcessSignature {
    param([int]$ProcessId)
    try {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    } catch { return $null }
    if (-not $p) { return $null }
    [pscustomobject]@{
        Pid         = $p.ProcessId
        Name        = $p.Name
        CommandLine = $p.CommandLine
        ExecutablePath = $p.ExecutablePath
    }
}

function Is-AgentmemoryOwned {
    param($sig)
    if (-not $sig) { return $false }
    $name = ($sig.Name -as [string]).ToLowerInvariant()
    $cmd  = ($sig.CommandLine -as [string])
    $exe  = ($sig.ExecutablePath -as [string])
    if ($name -like 'iii*') { return $true }
    if ($cmd -and $cmd -match '(?i)agentmemory') { return $true }
    if ($cmd -and $cmd -match '(?i)@agentmemory[\\/]') { return $true }
    if ($cmd -and $cmd -match '(?i)iii-engine') { return $true }
    if ($exe -and $exe -match '(?i)agentmemory') { return $true }
    return $false
}

function Stop-AgentmemoryProcesses {
    param([switch]$IncludeStrangers)
    $ports = @($cfg.restPort, $cfg.streamsPort, $cfg.viewerPort, $cfg.viewerFallbackPort, $cfg.enginePort)
    $holders = Get-PortHolders -Ports $ports

    $killed = @()
    foreach ($processId in $holders.Keys) {
        $sig = Get-ProcessSignature -ProcessId $processId
        $owned = Is-AgentmemoryOwned $sig
        if (-not $owned -and -not $IncludeStrangers) {
            Write-Log ("Skipping foreign process holding {0}: pid={1} name={2} cmd={3}" -f ($holders[$processId] -join ','), $processId, $sig.Name, $sig.CommandLine) WARN
            continue
        }
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            $killed += [pscustomobject]@{ Pid = $processId; Name = $sig.Name; Ports = $holders[$processId] }
            Write-Log ("Killed pid={0} name={1} ports={2}" -f $processId, $sig.Name, ($holders[$processId] -join ','))
        } catch {
            Write-Log ("Failed to kill pid={0}: {1}" -f $processId, $_.Exception.Message) WARN
        }
    }

    # Also sweep any iii*.exe regardless of port (pidfile-orphaned engines).
    Get-Process -Name 'iii' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
            $killed += [pscustomobject]@{ Pid = $_.Id; Name = $_.ProcessName; Ports = @() }
            Write-Log ("Killed orphan iii pid={0}" -f $_.Id)
        } catch {}
    }

    return $killed
}

function Wait-PortsReleased {
    param([int[]]$Ports, [int]$TimeoutSec = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $stillUp = @()
        foreach ($p in $Ports) {
            $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
            if ($conn) { $stillUp += $p }
        }
        if ($stillUp.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Clear-StaleAgentmemoryState {
    foreach ($f in @($PidFile, $EngineStateFile)) {
        if (Test-Path $f) {
            try {
                Remove-Item $f -Force -ErrorAction Stop
                Write-Log "Removed stale state file: $f"
            } catch {
                Write-Log "Could not remove $f - $($_.Exception.Message)" WARN
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Start agentmemory daemon detached
# ---------------------------------------------------------------------------

function Find-AgentmemoryCli {
    if ($cfg.PSObject.Properties.Name -contains 'agentmemoryCli' -and $cfg.agentmemoryCli) {
        $explicit = Expand-EnvPath $cfg.agentmemoryCli
        if (Test-Path $explicit) { return $explicit }
    }
    $candidates = @(
        (Join-Path $env:APPDATA 'npm\node_modules\@agentmemory\agentmemory\dist\cli.mjs'),
        (Join-Path $env:ProgramFiles 'nodejs\node_modules\@agentmemory\agentmemory\dist\cli.mjs')
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $shim = Join-Path $env:APPDATA 'npm\agentmemory.cmd'
    if (Test-Path $shim) { return $shim }
    return $null
}

function Start-Agentmemory {
    $cli = Find-AgentmemoryCli
    if (-not $cli) {
        Write-Log "Could not locate agentmemory CLI. Install with: npm i -g @agentmemory/agentmemory" ERROR
        return $false
    }

    $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if ($cli -like '*.cmd' -or $cli -like '*.bat') {
        $exe = $cli
        $argList = @()
    } elseif ($node) {
        $exe = $node
        $argList = @(('"{0}"' -f $cli))
    } else {
        Write-Log "node.exe not found on PATH; cannot start agentmemory" ERROR
        return $false
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    $stdoutLog = Join-Path $LogDir "agentmemory-stdout-$stamp.log"
    $stderrLog = Join-Path $LogDir "agentmemory-stderr-$stamp.log"

    try {
        $spArgs = @{
            FilePath               = $exe
            WorkingDirectory       = $env:USERPROFILE
            WindowStyle            = 'Hidden'
            PassThru               = $true
            RedirectStandardOutput = $stdoutLog
            RedirectStandardError  = $stderrLog
        }
        if ($argList.Count -gt 0) { $spArgs['ArgumentList'] = $argList }
        $proc = Start-Process @spArgs
    } catch {
        Write-Log ("Failed to spawn agentmemory: {0}" -f $_.Exception.Message) ERROR
        return $false
    }

    Write-Log ("Spawned agentmemory pid={0} via {1}; stdout={2}" -f $proc.Id, $exe, $stdoutLog)
    return $true
}

function Wait-Healthy {
    param([int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $h = Test-Health -TimeoutMs 3000
        if ($h.Healthy) { return $true }
        Start-Sleep -Seconds 2
    }
    return $false
}

# ---------------------------------------------------------------------------
# Full restart cycle
# ---------------------------------------------------------------------------

function Invoke-Restart {
    param([string]$Reason)
    Write-Log "RESTART begin: $Reason"

    # 1. Best-effort graceful stop, hard-bounded so a hung engine cannot block us.
    $shim = Join-Path $env:APPDATA 'npm\agentmemory.cmd'
    if (Test-Path $shim) {
        try {
            $job = Start-Job -ScriptBlock { param($s) & $s stop --force *> $null } -ArgumentList $shim
            if (-not (Wait-Job $job -Timeout 8)) {
                Write-Log "graceful 'agentmemory stop' timed out after 8s; proceeding to surgical kill" WARN
                Stop-Job $job -ErrorAction SilentlyContinue
            }
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } catch {
            Write-Log ("graceful stop threw: {0}" -f $_.Exception.Message) WARN
        }
    }

    # 2. Surgical kill of our processes holding our ports.
    $killed = @(Stop-AgentmemoryProcesses)
    Write-Log ("Reclaimed {0} process(es)" -f $killed.Count)

    # 3. Wait for ports to drain.
    $ports = @($cfg.restPort, $cfg.streamsPort, $cfg.viewerPort, $cfg.viewerFallbackPort, $cfg.enginePort)
    if (-not (Wait-PortsReleased -Ports $ports -TimeoutSec 10)) {
        Write-Log "Some ports still listening after 10s; trying stranger sweep" WARN
        Stop-AgentmemoryProcesses -IncludeStrangers | Out-Null
        Wait-PortsReleased -Ports $ports -TimeoutSec 5 | Out-Null
    }

    # 4. Clear stale pid / engine-state so a fresh start is not refused.
    Clear-StaleAgentmemoryState

    # 5. Start fresh.
    if (-not (Start-Agentmemory)) {
        Write-Log "Start-Agentmemory returned false" ERROR
        return $false
    }

    # 6. Wait for /status to come up.
    if (Wait-Healthy -TimeoutSec ([int]$cfg.startupTimeoutSec)) {
        Write-Log "RESTART success"
        return $true
    } else {
        Write-Log "Daemon did not become healthy within timeout" ERROR
        return $false
    }
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

function Invoke-Once {
    $state = Load-State

    $health = Test-Health -TimeoutMs ([int]$cfg.healthCheckTimeoutSec * 1000)
    if ($health.Healthy) {
        Write-Log ("Healthy ({0} {1})" -f $health.Path, $health.Code) DEBUG
        $state.lastHealthyAt = (Get-Date).ToString('o')
        Save-State $state
        return $true
    }

    Write-Log ("Unhealthy: {0}" -f $health.Error) WARN

    # Rate-limit restarts.
    $now = Get-Date
    $cutoff = $now.AddHours(-1)
    $recent = @($state.restartHistory | Where-Object { $_ -and ([datetime]$_) -gt $cutoff })
    if ($recent.Count -ge [int]$cfg.maxRestartsPerHour) {
        Write-Log ("Rate limit: {0} restarts in last hour - holding back" -f $recent.Count) WARN
        return $false
    }

    $ok = Invoke-Restart -Reason "health probe failed"
    $state.restartHistory = @($recent) + @($now.ToString('o'))
    if ($ok) { $state.lastHealthyAt = (Get-Date).ToString('o') }
    Save-State $state
    return $ok
}

function Invoke-Daemon {
    Write-Log "Keeper daemon starting (pid=$PID, config=$ConfigPath)"
    Rotate-OldLogs

    $consecutiveFailures = 0
    $lastTickAt          = Get-Date
    $skewThreshold       = [int]$cfg.clockSkewSleepDetectSec

    while ($true) {
        try {
            $now  = Get-Date
            $skew = ($now - $lastTickAt).TotalSeconds
            $lastTickAt = $now

            if ($skew -gt $skewThreshold) {
                Write-Log ("Clock skew {0:N0}s detected (sleep/wake/standby) - forcing restart cycle" -f $skew) WARN
                $consecutiveFailures = [int]$cfg.consecutiveFailuresBeforeRestart
            }

            $health = Test-Health -TimeoutMs ([int]$cfg.healthCheckTimeoutSec * 1000)

            if ($health.Healthy -and $consecutiveFailures -lt [int]$cfg.consecutiveFailuresBeforeRestart) {
                if ($consecutiveFailures -gt 0) {
                    Write-Log ("Recovered after {0} failure(s)" -f $consecutiveFailures)
                }
                $consecutiveFailures = 0
                $st = Load-State
                $st.lastHealthyAt = (Get-Date).ToString('o')
                Save-State $st
            } else {
                if (-not $health.Healthy) {
                    $consecutiveFailures++
                    Write-Log ("Health check failed (#{0}): {1}" -f $consecutiveFailures, $health.Error) WARN
                }

                if ($consecutiveFailures -ge [int]$cfg.consecutiveFailuresBeforeRestart) {
                    $state = Load-State
                    $cutoff = (Get-Date).AddHours(-1)
                    $recent = @($state.restartHistory | Where-Object { $_ -and ([datetime]$_) -gt $cutoff })
                    if ($recent.Count -ge [int]$cfg.maxRestartsPerHour) {
                        Write-Log ("Rate limit reached ({0}/hr) - backing off" -f $recent.Count) WARN
                        Start-Sleep -Seconds ([int]$cfg.restartCooldownSec)
                    } else {
                        $ok = Invoke-Restart -Reason ("{0} consecutive failures" -f $consecutiveFailures)
                        $state.restartHistory = @($recent) + @((Get-Date).ToString('o'))
                        Save-State $state
                        if ($ok) {
                            $consecutiveFailures = 0
                            Start-Sleep -Seconds ([int]$cfg.restartCooldownSec)
                        }
                    }
                }
            }
        } catch {
            Write-Log ("Loop exception: {0}" -f $_.Exception.Message) ERROR
        }

        Start-Sleep -Seconds ([int]$cfg.healthCheckIntervalSec)
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($Once) {
    $ok = Invoke-Once
    exit ([int](-not $ok))
}

if ($Daemon) {
    Invoke-Daemon
    exit 0
}

Write-Host "Usage: keeper.ps1 -Daemon | -Once"
Write-Host "Use ctl.ps1 for interactive operations."
exit 1
