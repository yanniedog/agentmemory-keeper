# Repository instructions

This repository supervises the external agentmemory daemon on the local
Windows machine. Never SSH to a Pi or install the daemon there.

## Components

- `watcher.mjs` uses Node.js built-ins and global fetch. No npm dependencies
  or build step are required. It reads transcripts and posts observations
  to the local REST API.
- PowerShell scripts manage Windows processes and scheduled tasks. Read
  README.md before operating them. Verification must not restart the user's
  daemon or alter scheduled tasks.

## Verification

- Run `node --check watcher.mjs` and `node --test watcher.test.mjs`.
- The regression test uses isolated empty transcript and state directories,
  dry-run mode, and a closed loopback port. Never ingest personal history in tests.
- Parse changed PowerShell files with the PowerShell language parser.
- Use a topic branch and PR; preserve unrelated local changes.

## Local watcher operation

`node watcher.mjs --once` scans recent transcripts and exits after the scan.
The refill timer is unreferenced so it does not keep a completed scan alive.
Normal daemon mode remains alive through its file watchers and scan timers.

Cursor transcript lines have this JSON shape:

```json
{"role":"user","message":{"content":[{"type":"text","text":"hello"}]}}
```

State defaults to `agentmemory-keeper` under LOCALAPPDATA, falling back to
 the user's home directory. AGENTMEMORY_KEEPER_STATE_DIR overrides it.
Dry runs advance saved offsets too; use an isolated state directory for tests.
Do not delete production state or replay old transcripts during verification.

The default REST endpoint is http://127.0.0.1:3111; use a read-only health
check when needed. Daemon configuration and data belong to the local user.
