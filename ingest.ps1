<#
.SYNOPSIS
  Re-import historical AI transcripts into agentmemory.

.DESCRIPTION
  agentmemory's "Token Savings" stat card needs raw observation data to
  compute against. The Claude Code hook chain populates this in real time,
  but historical transcripts only show up after a bulk import. This script
  runs `agentmemory import-jsonl` against every supported transcript
  source on the machine and reports the result.

  Currently supported sources (agentmemory 0.9.21):
    - Claude Code     ~/.claude/projects/**/*.jsonl   (native format)

  Not yet supported by upstream:
    - Cursor          ~/.cursor/projects/<workspace>/agent-transcripts/
    - Codex           ~/.codex/sessions/**/*.jsonl    (different schema)

.PARAMETER MaxFiles
  Cap on files per source. Defaults to 200 (the upstream importer cap).
  Pass higher numbers to drain a large backlog (max 1000 per upstream).

.PARAMETER DryRun
  List what would be imported without invoking agentmemory.

.EXAMPLE
  .\ingest.ps1                   # import everything (default cap)
  .\ingest.ps1 -MaxFiles 1000    # drain a big backlog
  .\ingest.ps1 -DryRun           # show counts only
#>

[CmdletBinding()]
param(
    [int]$MaxFiles = 200,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$env:AGENTMEMORY_URL = if ($env:AGENTMEMORY_URL) { $env:AGENTMEMORY_URL } else { 'http://127.0.0.1:3111' }

function Format-Section($title) {
    Write-Host ''
    Write-Host ("== {0} {1}" -f $title, ('=' * [Math]::Max(0, 60 - $title.Length))) -ForegroundColor Cyan
}

Format-Section "Pre-import savings snapshot"
try {
    $sessions = (Invoke-WebRequest "$env:AGENTMEMORY_URL/agentmemory/sessions" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
    $sessionsArr = $sessions.sessions
    $obs = ($sessionsArr | Measure-Object observationCount -Sum).Sum
    Write-Host ("  sessions     : {0}" -f $sessionsArr.Count)
    Write-Host ("  observations : {0}" -f ([int]$obs))
} catch {
    Write-Host "  agentmemory not responding ($($_.Exception.Message))" -ForegroundColor Red
    exit 1
}

Format-Section "Sources"
$claudeRoot = Join-Path $env:USERPROFILE '.claude\projects'
$claudeFiles = if (Test-Path $claudeRoot) { @(Get-ChildItem $claudeRoot -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue) } else { @() }
$claudeSize  = if ($claudeFiles.Count -gt 0) { ($claudeFiles | Measure-Object Length -Sum).Sum } else { 0 }
Write-Host ("  Claude Code  : {0,5} jsonl files, {1:N1} MB at {2}" -f $claudeFiles.Count, ($claudeSize / 1MB), $claudeRoot)

$cursorRoot = Join-Path $env:USERPROFILE '.cursor\projects'
$cursorCount = 0
if (Test-Path $cursorRoot) {
    Get-ChildItem $cursorRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $att = Join-Path $_.FullName 'agent-transcripts'
        if (Test-Path $att) { $cursorCount += @(Get-ChildItem $att -File -ErrorAction SilentlyContinue).Count }
    }
}
Write-Host ("  Cursor       : {0,5} files (not yet supported by upstream agentmemory)" -f $cursorCount)

$codexRoot = Join-Path $env:USERPROFILE '.codex\sessions'
$codexFiles = if (Test-Path $codexRoot) { @(Get-ChildItem $codexRoot -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue) } else { @() }
Write-Host ("  Codex        : {0,5} jsonl files (different schema, not yet supported)" -f $codexFiles.Count)

if ($DryRun) {
    Format-Section "Dry run - exiting"
    exit 0
}

if ($claudeFiles.Count -gt 0) {
    Format-Section "Importing Claude Code transcripts"
    # agentmemory import-jsonl scans recursively from the path given.
    & agentmemory import-jsonl $claudeRoot --max-files $MaxFiles 2>&1 | ForEach-Object {
        # Drop the noisy clack spinner frames; keep only the actual result line.
        if ($_ -is [string] -and $_ -notmatch 'scanning files' -and $_.Trim()) {
            Write-Host $_
        }
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  import exited with code $LASTEXITCODE" -ForegroundColor Yellow
    }
}

Format-Section "Post-import savings"
try {
    $sessions = (Invoke-WebRequest "$env:AGENTMEMORY_URL/agentmemory/sessions" -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
    $sessionsArr = $sessions.sessions
    $obs = ($sessionsArr | Measure-Object observationCount -Sum).Sum
    $tokenBudget = 2000
    $estFull = $obs * 80
    $estInjected = $sessionsArr.Count * $tokenBudget
    $savingsPct = if ($estFull -gt 0) { [Math]::Round((1 - $estInjected / $estFull) * 100, 1) } else { 0 }
    $tokensSaved = [Math]::Max(0, $estFull - $estInjected)
    $cost = [Math]::Round($tokensSaved / 1000 * 0.30, 2)

    Write-Host ("  sessions     : {0}" -f $sessionsArr.Count)
    Write-Host ("  observations : {0}" -f ([int]$obs))
    Write-Host ''
    Write-Host ('  +------------------------------------------+') -ForegroundColor Green
    Write-Host ('  |  Token savings : {0,6}%                  |' -f $savingsPct) -ForegroundColor Green
    Write-Host ('  |  Tokens saved  : {0,12:N0}            |' -f $tokensSaved) -ForegroundColor Green
    Write-Host ('  |  ~Cost saved   : ${0,11:N2}             |' -f $cost) -ForegroundColor Green
    Write-Host ('  +------------------------------------------+') -ForegroundColor Green
    Write-Host ''
    Write-Host ('  View live dashboard: http://127.0.0.1:3113/')
} catch {
    Write-Host "  could not read sessions: $($_.Exception.Message)" -ForegroundColor Red
}
