# AGENTS.md

## Cursor Cloud specific instructions

This repo (`agentmemory-keeper`) is a Windows-first supervisor for the external
`@agentmemory/agentmemory` daemon. The cloud VM is Linux, so the parts that
matter differ from the README's Windows guidance:

### Components
- `watcher.mjs` — cross-platform Node.js (ESM, no npm deps, uses global `fetch`).
  This is the only runnable/testable app on Linux. It tails Cursor/Codex
  transcripts and POSTs observations to the agentmemory REST API.
- `*.ps1` (`ctl.ps1`, `keeper.ps1`, `install.ps1`, `ingest.ps1`, `uninstall.ps1`)
  — Windows-only PowerShell (Scheduled Tasks, `Win32_Process`,
  `Get-NetTCPConnection`, hidden `powershell.exe` launches). They will NOT
  execute meaningfully on Linux; on the VM they can only be lint/parse-checked
  with PowerShell 7 (`pwsh`, installed) + PSScriptAnalyzer.
- `@agentmemory/agentmemory` — the external daemon the scripts supervise. Not in
  this repo. Installed globally to `~/.npm-global` (see update script). Its CLI
  is `agentmemory`; the `~/.npm-global/bin` dir is added to `PATH` via `~/.bashrc`.

### Running the daemon (the "application")
- Start with `agentmemory` (add `--verbose` for boot logs). REST is at
  `http://127.0.0.1:3111/agentmemory/*`, viewer at `http://127.0.0.1:3113`,
  streams `3112`, iii-engine `49134`.
- FIRST start is interactive: it prompts to install the `iii-engine` binary
  (accept "Install iii ... (recommended)") into `~/.agentmemory/bin`, then
  prompts "Install iii console? Yes/No" (choose No). After the binary exists,
  subsequent starts are non-interactive. Run it in a tmux session, not as a
  one-shot background job, because of these prompts.
- Health check: `curl -s http://127.0.0.1:3111/agentmemory/livez` → `{"status":"ok"}`.
- No LLM key is configured; it runs with the no-op provider / BM25-only mode,
  which is fine for exercising the observe/session pipeline.

### Running / testing the watcher
- Lint: `node --check watcher.mjs`.
- End-to-end: `node watcher.mjs --once` scans `~/.cursor/projects/*/agent-transcripts/<uuid>/<uuid>.jsonl`
  and `~/.codex/sessions/**/*.jsonl`, registers sessions, and POSTs observations.
  A fresh VM has no transcripts, so create one under the Cursor path in the real
  schema (`{"role":"user"|"assistant","message":{"content":[...]}}`) to exercise it.
- GOTCHA: `node watcher.mjs --once` finishes its scan (logs `--once: exiting after
  initial scan`) but the process does NOT actually exit — a top-level
  `setInterval` token-refill timer keeps the event loop alive. Wrap it, e.g.
  `timeout 15 node watcher.mjs --once`, or Ctrl-C it. Its work is done as soon as
  the scan line is logged.
- GOTCHA: offsets/registered sessions persist in `~/agentmemory-keeper/watcher-state.json`.
  A `--dry-run` pass still advances offsets, so a following real run ships nothing.
  Delete that state file (or pass `--since-zero`) to re-deliver from the start.
- Verify delivery: `curl -s http://127.0.0.1:3111/agentmemory/sessions` or
  `agentmemory status` (shows session/observation counts + the Token Savings
  metric that `ctl.ps1 savings` reports on Windows).

### Notes
- Global npm installs use a user prefix (`~/.npm-global`); this triggers a benign
  "prefix ... incompatible with nvm" warning on every npm/node-launched command.
  It is only a warning and does not affect execution.
- There is no `package.json`, no automated test suite, and no build step in this repo.
