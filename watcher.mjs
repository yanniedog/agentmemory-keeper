#!/usr/bin/env node
/**
 * agentmemory-keeper watcher
 *
 * Streams transcript activity from Cursor and Codex into agentmemory in
 * near-real-time. Claude Code already feeds agentmemory via its hook
 * chain; this watcher fills in the two clients that do not.
 *
 *   Cursor: ~/.cursor/projects/<workspace>/agent-transcripts/<uuid>/<uuid>.jsonl
 *   Codex : ~/.codex/sessions/**\/*.jsonl
 *
 * Design notes:
 *
 * - Tail-based, not import-based: each known file has a saved byte offset
 *   in watcher-state.json. On startup the watcher catches up from the
 *   saved offset and never re-sends entries it has already shipped.
 *
 * - Resilient to engine outages: failed POSTs are queued to a local NDJSON
 *   file and replayed by a background drain loop when the engine returns.
 *
 * - Throttled: a token bucket caps observation POSTs to ~5/sec by default
 *   so a large catch-up burst cannot crash the iii-engine the way a raw
 *   `agentmemory import-jsonl` of a 50 MB tree can.
 *
 * - The watcher registers a session via POST /agentmemory/session/start
 *   the first time it sees a session id, then POSTs every subsequent
 *   transcript entry as POST /agentmemory/observe — the same surface the
 *   Claude Code hook chain uses.
 *
 * Usage:
 *   node watcher.mjs                # daemon, tails forever
 *   node watcher.mjs --once         # one catch-up scan then exit
 *   node watcher.mjs --dry-run      # print what would be sent
 *   node watcher.mjs --since-zero   # ignore saved offsets and re-send
 *
 * Env:
 *   AGENTMEMORY_URL                 # default http://127.0.0.1:3111
 *   AGENTMEMORY_KEEPER_STATE_DIR    # default %LOCALAPPDATA%\agentmemory-keeper
 *   AGENTMEMORY_WATCHER_RATE        # max observations per second (default 5)
 *   AGENTMEMORY_WATCHER_BATCH_MS    # flush window ms (default 1500)
 */

import { promises as fs, watch as fsWatch, createReadStream, statSync } from 'node:fs';
import { join, basename, dirname, relative } from 'node:path';
import { homedir, EOL } from 'node:os';

const REST_URL  = process.env.AGENTMEMORY_URL || 'http://127.0.0.1:3111';
const STATE_DIR = process.env.AGENTMEMORY_KEEPER_STATE_DIR || join(process.env.LOCALAPPDATA || homedir(), 'agentmemory-keeper');
const STATE_FILE  = join(STATE_DIR, 'watcher-state.json');
const QUEUE_FILE  = join(STATE_DIR, 'watcher-queue.ndjson');
const LOG_DIR     = join(STATE_DIR, 'logs');
// Default rate is intentionally conservative. The iii-engine has periodic
// internal consolidation cycles that can spike CPU and briefly stop
// serving HTTP. A high observation rate stacks onto those windows and
// causes cascading restarts. 2 obs/sec is plenty for catch-up work
// without disturbing live agent activity.
const RATE_PER_S  = Number.parseInt(process.env.AGENTMEMORY_WATCHER_RATE || '2', 10);
const BATCH_MS    = Number.parseInt(process.env.AGENTMEMORY_WATCHER_BATCH_MS || '2500', 10);

const argv = new Set(process.argv.slice(2));
const ONCE      = argv.has('--once');
const DRY_RUN   = argv.has('--dry-run');
const SINCE_ZERO= argv.has('--since-zero');

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

let logPath;
function logfile() {
  const stamp = new Date().toISOString().slice(0, 10);
  return join(LOG_DIR, `watcher-${stamp}.log`);
}
async function log(level, msg) {
  const line = `${new Date().toISOString()} [${level}] ${msg}\n`;
  process.stdout.write(line);
  try {
    if (!logPath || logPath !== logfile()) logPath = logfile();
    await fs.appendFile(logPath, line, 'utf8');
  } catch {}
}
const info  = (m) => log('INFO',  m);
const warn  = (m) => log('WARN',  m);
const error = (m) => log('ERROR', m);

// ---------------------------------------------------------------------------
// State (per-file offsets + known session registrations)
// ---------------------------------------------------------------------------

async function ensureDir(d) { await fs.mkdir(d, { recursive: true }); }

async function loadState() {
  try {
    const raw = await fs.readFile(STATE_FILE, 'utf8');
    return JSON.parse(raw);
  } catch {
    return { offsets: {}, registered: {} };
  }
}
let saveStateTimer = null;
let pendingState = null;
function scheduleSave(s) {
  pendingState = s;
  if (saveStateTimer) return;
  saveStateTimer = setTimeout(async () => {
    saveStateTimer = null;
    try { await fs.writeFile(STATE_FILE, JSON.stringify(pendingState, null, 2), 'utf8'); }
    catch (e) { warn(`state save failed: ${e.message}`); }
  }, 500);
}

// ---------------------------------------------------------------------------
// Throttled fetch with offline queue
// ---------------------------------------------------------------------------

let tokens = RATE_PER_S;
setInterval(() => { tokens = Math.min(RATE_PER_S, tokens + RATE_PER_S); }, 1000);

async function take() {
  while (tokens <= 0) await new Promise((r) => setTimeout(r, 200));
  tokens--;
}

async function postJson(path, payload, timeoutMs = 4000) {
  const ctl = new AbortController();
  const to = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(`${REST_URL}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: ctl.signal,
    });
    return { ok: r.ok, status: r.status };
  } catch (e) {
    return { ok: false, status: 0, error: String(e?.message || e) };
  } finally {
    clearTimeout(to);
  }
}

async function queueAppend(record) {
  try {
    await fs.appendFile(QUEUE_FILE, JSON.stringify(record) + '\n', 'utf8');
  } catch (e) {
    warn(`queue append failed: ${e.message}`);
  }
}

async function flushQueue() {
  let raw;
  try { raw = await fs.readFile(QUEUE_FILE, 'utf8'); }
  catch (e) { return; /* no queue */ }
  if (!raw.trim()) return;
  const lines = raw.split(/\r?\n/).filter(Boolean);
  const survivors = [];
  let sent = 0;
  for (const line of lines) {
    let rec;
    try { rec = JSON.parse(line); } catch { continue; }
    await take();
    const r = await postJson(rec.path, rec.payload);
    if (r.ok) { sent++; }
    else { survivors.push(rec); }
  }
  if (sent > 0) info(`queue: replayed ${sent} entries (${survivors.length} still queued)`);
  try {
    if (survivors.length === 0) await fs.unlink(QUEUE_FILE).catch(() => {});
    else await fs.writeFile(QUEUE_FILE, survivors.map((s) => JSON.stringify(s)).join('\n') + '\n', 'utf8');
  } catch (e) { warn(`queue rewrite failed: ${e.message}`); }
}

// Cached engine liveness so we do not hammer livez before every POST.
// Refreshed lazily after a POST failure or every 30 seconds.
let engineAlive = true;
let engineCheckedAt = 0;
async function engineLivez() {
  const now = Date.now();
  if (engineAlive && now - engineCheckedAt < 30_000) return true;
  engineCheckedAt = now;
  try {
    const ctl = new AbortController();
    const to = setTimeout(() => ctl.abort(), 2500);
    const r = await fetch(`${REST_URL}/agentmemory/livez`, { signal: ctl.signal });
    clearTimeout(to);
    engineAlive = r.ok;
  } catch {
    engineAlive = false;
  }
  return engineAlive;
}

async function deliver(path, payload) {
  if (DRY_RUN) {
    process.stdout.write(`[DRY] POST ${path} ${JSON.stringify(payload).slice(0, 160)}\n`);
    return true;
  }
  // If we know the engine is down, queue without burning a token bucket or
  // making a doomed POST. The drain loop will retry every 60s.
  if (!(await engineLivez())) {
    await queueAppend({ path, payload });
    return false;
  }
  await take();
  const r = await postJson(path, payload);
  if (r.ok) return true;
  // Mark engine unhealthy on 5xx / network so subsequent calls go straight
  // to the queue and stop adding load.
  if (r.status === 0 || r.status >= 500) {
    engineAlive = false;
    engineCheckedAt = Date.now();
  }
  if (r.status >= 400 && r.status < 500) {
    warn(`drop ${r.status} ${path}: ${JSON.stringify(payload).slice(0, 120)}`);
    return false;
  }
  await queueAppend({ path, payload });
  return false;
}

// ---------------------------------------------------------------------------
// Source-specific entry mappers
// ---------------------------------------------------------------------------

function inferCursorContext(filePath) {
  // .cursor/projects/<workspace>/agent-transcripts/<uuid>/<uuid>.jsonl
  const parts = filePath.split(/[\\/]/);
  const projIdx = parts.findIndex((p) => p === 'projects');
  const workspace = (projIdx >= 0 && parts[projIdx + 1]) ? parts[projIdx + 1] : 'cursor';
  const sessionId = (parts[parts.length - 2] || '').replace(/[^a-zA-Z0-9_-]/g, '');
  // Workspaces are slug-encoded with `-` instead of `\` / `:`. Best effort
  // round-trip into a usable cwd string: c-code-AR-local -> C:/code/AR-local.
  const cwdGuess = workspace.replace(/^([a-zA-Z])-/, '$1:/').replace(/-/g, '/');
  return { sessionId, project: workspace, cwd: cwdGuess };
}

function inferCodexContext(filePath, sessionMetaPayload) {
  const sessionId = sessionMetaPayload?.id || basename(filePath, '.jsonl').replace(/^rollout-[^-]+-/, '');
  const cwd = sessionMetaPayload?.cwd || homedir();
  const project = cwd.split(/[\\/]/).filter(Boolean).pop() || 'codex';
  return { sessionId, project, cwd };
}

function mapCursorLine(ctx, lineObj) {
  if (lineObj?.role === 'user') {
    return {
      hookType: 'user_prompt_submit',
      data: { source: 'cursor', content: lineObj.message?.content || [] },
    };
  }
  if (lineObj?.role === 'assistant') {
    const c = lineObj.message?.content || [];
    const tools = c.filter((p) => p?.type === 'tool_use');
    if (tools.length > 0) {
      return {
        hookType: 'post_tool_use',
        data: { source: 'cursor', tools: tools.map((t) => ({ name: t.name, input: t.input })) },
      };
    }
    return {
      hookType: 'assistant_message',
      data: { source: 'cursor', content: c },
    };
  }
  return null;
}

function mapCodexLine(ctx, lineObj) {
  const t = lineObj?.type;
  if (t === 'response_item') {
    const payload = lineObj.payload || {};
    if (payload?.type === 'message' && payload?.role === 'user') {
      return { hookType: 'user_prompt_submit', data: { source: 'codex', content: payload.content || [] } };
    }
    if (payload?.type === 'message' && payload?.role === 'assistant') {
      return { hookType: 'assistant_message', data: { source: 'codex', content: payload.content || [] } };
    }
    if (payload?.type === 'function_call' || payload?.type === 'tool_call') {
      return { hookType: 'post_tool_use', data: { source: 'codex', tool: payload.name, args: payload.arguments } };
    }
  }
  if (t === 'event_msg' && lineObj.payload?.type === 'task_started') {
    return { hookType: 'task_started', data: { source: 'codex', payload: lineObj.payload } };
  }
  if (t === 'event_msg' && lineObj.payload?.type === 'task_completed') {
    return { hookType: 'task_completed', data: { source: 'codex', payload: lineObj.payload } };
  }
  return null;
}

// ---------------------------------------------------------------------------
// Per-source processing
// ---------------------------------------------------------------------------

async function readAppendedLines(filePath, fromOffset) {
  let st;
  try { st = statSync(filePath); } catch { return { lines: [], nextOffset: fromOffset }; }
  if (st.size <= fromOffset) return { lines: [], nextOffset: fromOffset };
  return await new Promise((resolve, reject) => {
    const chunks = [];
    const stream = createReadStream(filePath, { start: fromOffset, encoding: 'utf8' });
    stream.on('data', (c) => chunks.push(c));
    stream.on('end', () => {
      const text = chunks.join('');
      const lines = text.split(/\r?\n/);
      // Last element is partial if file didn't end with newline.
      const partial = !text.endsWith('\n') ? lines.pop() : '';
      const consumed = text.length - (partial?.length ?? 0);
      resolve({ lines: lines.filter(Boolean), nextOffset: fromOffset + Buffer.byteLength(text.slice(0, consumed), 'utf8') });
    });
    stream.on('error', reject);
  });
}

async function ensureSessionRegistered(state, ctx) {
  if (state.registered[ctx.sessionId]) return;
  await deliver('/agentmemory/session/start', { sessionId: ctx.sessionId, project: ctx.project, cwd: ctx.cwd });
  state.registered[ctx.sessionId] = new Date().toISOString();
  scheduleSave(state);
}

async function processCursorFile(state, filePath) {
  const ctx = inferCursorContext(filePath);
  if (!ctx.sessionId) return;
  await ensureSessionRegistered(state, ctx);
  const fromOffset = SINCE_ZERO ? 0 : (state.offsets[filePath] || 0);
  const { lines, nextOffset } = await readAppendedLines(filePath, fromOffset);
  let shipped = 0;
  for (const line of lines) {
    let obj; try { obj = JSON.parse(line); } catch { continue; }
    const m = mapCursorLine(ctx, obj);
    if (!m) continue;
    await deliver('/agentmemory/observe', {
      hookType: m.hookType,
      sessionId: ctx.sessionId,
      project: ctx.project,
      cwd: ctx.cwd,
      timestamp: new Date().toISOString(),
      data: m.data,
    });
    shipped++;
  }
  state.offsets[filePath] = nextOffset;
  scheduleSave(state);
  if (shipped > 0) info(`cursor ${ctx.sessionId}: +${shipped} obs (${filePath})`);
}

async function processCodexFile(state, filePath) {
  const fromOffset = SINCE_ZERO ? 0 : (state.offsets[filePath] || 0);
  const { lines, nextOffset } = await readAppendedLines(filePath, fromOffset);
  let ctx = null;
  let shipped = 0;
  for (const line of lines) {
    let obj; try { obj = JSON.parse(line); } catch { continue; }
    if (obj?.type === 'session_meta') {
      ctx = inferCodexContext(filePath, obj.payload);
      await ensureSessionRegistered(state, ctx);
      continue;
    }
    if (!ctx) {
      // First-time seeing this file mid-stream — try to infer from filename.
      ctx = inferCodexContext(filePath, null);
      await ensureSessionRegistered(state, ctx);
    }
    const m = mapCodexLine(ctx, obj);
    if (!m) continue;
    await deliver('/agentmemory/observe', {
      hookType: m.hookType,
      sessionId: ctx.sessionId,
      project: ctx.project,
      cwd: ctx.cwd,
      timestamp: obj.timestamp || new Date().toISOString(),
      data: m.data,
    });
    shipped++;
  }
  state.offsets[filePath] = nextOffset;
  scheduleSave(state);
  if (shipped > 0 && ctx) info(`codex ${ctx.sessionId}: +${shipped} obs (${basename(filePath)})`);
}

// ---------------------------------------------------------------------------
// Discovery + scanning
// ---------------------------------------------------------------------------

async function listCursorFiles() {
  const root = join(homedir(), '.cursor', 'projects');
  const out = [];
  let workspaces;
  try { workspaces = await fs.readdir(root, { withFileTypes: true }); } catch { return out; }
  for (const ws of workspaces) {
    if (!ws.isDirectory()) continue;
    const att = join(root, ws.name, 'agent-transcripts');
    let uuids;
    try { uuids = await fs.readdir(att, { withFileTypes: true }); } catch { continue; }
    for (const u of uuids) {
      if (!u.isDirectory()) continue;
      const inner = join(att, u.name);
      let files;
      try { files = await fs.readdir(inner); } catch { continue; }
      for (const f of files) {
        if (f.endsWith('.jsonl')) out.push(join(inner, f));
      }
    }
  }
  return out;
}

async function listCodexFiles() {
  const root = join(homedir(), '.codex', 'sessions');
  const out = [];
  async function walk(dir) {
    let entries;
    try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) await walk(p);
      else if (e.isFile() && e.name.endsWith('.jsonl')) out.push(p);
    }
  }
  await walk(root);
  return out;
}

async function scanOnce(state) {
  const [cursorFiles, codexFiles] = await Promise.all([listCursorFiles(), listCodexFiles()]);
  for (const f of cursorFiles) await processCursorFile(state, f);
  for (const f of codexFiles)  await processCodexFile(state, f);
}

// ---------------------------------------------------------------------------
// Watch loop
// ---------------------------------------------------------------------------

async function watch(state) {
  const cursorRoot = join(homedir(), '.cursor', 'projects');
  const codexRoot  = join(homedir(), '.codex', 'sessions');

  // Coalesce events into a single scan per BATCH_MS window.
  let pending = false;
  function kick() {
    if (pending) return;
    pending = true;
    setTimeout(async () => {
      pending = false;
      try { await scanOnce(state); } catch (e) { warn(`scan: ${e.message}`); }
      try { await flushQueue(); } catch (e) { warn(`flush: ${e.message}`); }
    }, BATCH_MS);
  }

  for (const root of [cursorRoot, codexRoot]) {
    try {
      fsWatch(root, { recursive: true }, () => kick());
      info(`watching ${root}`);
    } catch (e) {
      warn(`fsWatch ${root} failed: ${e.message}; falling back to polling`);
    }
  }
  // Safety net poll in case fsWatch misses an event (Windows recursive watch
  // is reliable in modern Node but better safe than sorry on flaky FS).
  setInterval(kick, 30_000);
  // Periodic queue drain even when nothing new is being written.
  setInterval(() => flushQueue().catch(() => {}), 60_000);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  await ensureDir(STATE_DIR);
  await ensureDir(LOG_DIR);
  await info(`watcher starting (REST_URL=${REST_URL}, dryRun=${DRY_RUN}, once=${ONCE}, sinceZero=${SINCE_ZERO})`);
  const state = await loadState();
  await scanOnce(state);
  await flushQueue();
  if (ONCE) {
    await info('--once: exiting after initial scan');
    if (saveStateTimer) await new Promise((r) => setTimeout(r, 700));
    return;
  }
  await watch(state);
}

main().catch((e) => { error(`fatal: ${e.stack || e.message}`); process.exit(1); });
