# agentmemory-keeper

A small, opinionated supervisor for `@agentmemory/agentmemory` on Windows.

Designed for laptops that constantly move between Wi-Fi networks, VPNs,
airplane mode, hotel/airport hotspots, standby/resume cycles, and
BleachBit cache wipes — the kind of environment that turns agentmemory's
local daemon into a hung listening socket nobody can talk to.

It keeps the daemon healthy automatically. No admin rights required.

## What it solves

| Failure mode | What keeper does |
|---|---|
| `iii` process hangs after sleep/wake — port 3111 listens but never responds | Detects via fast HTTP probe (5s timeout), kills the hung process, clears stale `iii.pid`, restarts. |
| Clock jumps forward (laptop resumed from standby) | Clock-skew detection forces a restart cycle the moment you wake the lid. |
| Ghost browser tabs holding the viewer port (`3113`) | Surgical port reclamation: identifies which process owns each agentmemory port and kills only our processes (`iii.exe`, `node.exe` running `agentmemory/cli.mjs`) — never your browser. |
| Stale `iii.pid` blocks restart | Removed automatically before each restart. |
| `agentmemory stop --force` reports "still hold the port" | Keeper falls back to direct `Stop-Process` on the holders it owns. |
| Keeper itself crashes | Watchdog scheduled task restarts it every 5 minutes. |
| Reboot / login again | At-logon trigger starts keeper hidden, no flashing window. |
| Workstation unlock | Re-arms a health probe immediately. |
| Restart rate-limit / runaway loop | Max 6 restarts/hour by default; backs off rather than fighting a broken system. |
| BleachBit wiped `%TEMP%` or `%LOCALAPPDATA%` cache | Keeper regenerates state and logs on next start. Don't point BleachBit at `~/.agentmemory`. |
| VPN / airplane mode / hotel Wi-Fi | Irrelevant to localhost — keeper doesn't care about your external network. |

## Install

```powershell
git clone https://github.com/yanniedog/agentmemory-keeper.git C:\code\agentmemory-keeper
cd C:\code\agentmemory-keeper
.\ctl.ps1 install
```

That registers two user-scoped scheduled tasks (no UAC prompt, no admin) and
starts the keeper immediately. Verify:

```powershell
.\ctl.ps1 status
```

## Daily use

```powershell
.\ctl.ps1 status      # summary: daemon health, keeper pid, ports, last restarts
.\ctl.ps1 savings     # current Token Savings % from the dashboard's formula
.\ctl.ps1 ingest      # bulk-import all Claude Code transcripts (feeds savings)
.\ctl.ps1 logs        # tail today's keeper log
.\ctl.ps1 doctor      # full diagnostic dump for support
.\ctl.ps1 restart     # force a full reclamation + restart cycle
.\ctl.ps1 reclaim     # kill stuck processes / free ports (no restart)
.\ctl.ps1 stop        # stop keeper + daemon (e.g. before manual upgrade)
.\ctl.ps1 uninstall   # remove scheduled tasks (leaves agentmemory itself alone)
```

## Why does the dashboard show 0% token savings?

The Token Savings stat card on the agentmemory viewer (`http://127.0.0.1:3113`) computes:

```
estFull     = totalObservations * 80
estInjected = sessions * 2000
savings %   = (1 - estInjected / estFull) * 100
```

It needs **observations** to compute against. Claude Code's hook chain feeds observations live, but other clients (Cursor MCP, Codex MCP) only record explicit `memory_save` calls.

To seed the metric with historical data, run:

```powershell
.\ctl.ps1 ingest
```

This invokes `agentmemory import-jsonl` against `~/.claude/projects/`. A single import of a typical month of Claude Code sessions tends to surface 90%+ savings instantly. Cursor and Codex transcript imports are not yet supported upstream.

## Architecture

```
                        +--------------------------+
   At Logon  ---------> | Task: AgentmemoryKeeper  |
   On Unlock ---------> | (runs launch-hidden.vbs) |
                        +-----------+--------------+
                                    |
                                    v
                        +---------------------------+
                        |  keeper.ps1 -Daemon       |
                        |  - probe every 30s        |
                        |  - clock-skew = wake      |
                        |  - rate-limited restarts  |
                        |  - daily-rotated logs     |
                        +-----------+---------------+
                                    |
                                    v   (on failure)
                        +---------------------------+
                        |  Restart cycle:           |
                        |  1. agentmemory stop      |
                        |  2. surgical port kill    |
                        |  3. clear iii.pid         |
                        |  4. spawn daemon detached |
                        |  5. wait for /status      |
                        +---------------------------+

   Every 5 min -------> Task: AgentmemoryKeeperWatchdog
                        | - if keeper daemon missing, relaunch it
                        | - also runs `keeper.ps1 -Once` as belt-and-braces
```

The daemon runs entirely as the logged-in user. It only touches:

- Its own ports (`3111`, `3112`, `3113`, `3119`, `49134` by default).
- Processes whose `Win32_Process.CommandLine` matches `agentmemory`,
  `@agentmemory/`, `iii-engine`, or whose name starts with `iii`.

Foreign processes holding agentmemory's ports are logged but never killed
unless `Stop-AgentmemoryProcesses -IncludeStrangers` is invoked manually.

## Configuration

`config.json` (override any field as needed):

```json
{
  "restPort": 3111,
  "viewerPort": 3113,
  "viewerFallbackPort": 3119,
  "enginePort": 49134,

  "healthCheckIntervalSec": 30,
  "healthCheckTimeoutSec": 5,
  "consecutiveFailuresBeforeRestart": 2,
  "restartCooldownSec": 60,
  "maxRestartsPerHour": 6,
  "startupTimeoutSec": 60,

  "clockSkewSleepDetectSec": 90,
  "logRetentionDays": 14
}
```

Tweak `healthCheckIntervalSec` lower if you want tighter recovery (at the cost
of more probes per minute).

## Logs

```
%LOCALAPPDATA%\agentmemory-keeper\logs\keeper-YYYY-MM-DD.log
%LOCALAPPDATA%\agentmemory-keeper\logs\agentmemory-stdout.log
%LOCALAPPDATA%\agentmemory-keeper\logs\agentmemory-stderr.log
%LOCALAPPDATA%\agentmemory-keeper\keeper-state.json
```

Logs older than 14 days are pruned automatically.

## Travel checklist

You can ignore this section — the keeper handles all of it. Included for
peace of mind:

- **VPN flips, Wi-Fi changes, airplane mode** — agentmemory is `127.0.0.1`
  only. Loopback is unaffected by network adapter state changes. The keeper
  doesn't even notice.
- **Hotel / airport Wi-Fi with captive portals** — same: loopback works.
- **Laptop standby** — clock skew >90s on resume triggers a fresh restart
  cycle within one probe interval (~30s).
- **Reboot** — keeper auto-starts at next logon.
- **BleachBit "Temporary files"** — fine.
- **BleachBit "Cache" for arbitrary apps** — fine unless you explicitly
  add `%USERPROFILE%\.agentmemory` to its target list. **Don't.**
- **Cursor / Claude Code / Codex restart** — agentmemory is independent.
  Each client reconnects to `http://127.0.0.1:3111` on its next MCP call.

## Uninstall

```powershell
.\ctl.ps1 uninstall
```

Removes both scheduled tasks and kills the running keeper. Does **not**
touch agentmemory, its data under `~/.agentmemory`, or any other software.

## Requirements

- Windows 10 / 11
- PowerShell 5.1+ (built-in)
- Node.js + `@agentmemory/agentmemory` installed globally
  (`npm i -g @agentmemory/agentmemory`)

## License

MIT.
