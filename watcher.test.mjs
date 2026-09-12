import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

test('one-shot scan exits without a live refill timer', async () => {
  const root = await mkdtemp(join(tmpdir(), 'keeper-once-'));
  try {
    const result = spawnSync(process.execPath,
      [fileURLToPath(new URL('./watcher.mjs', import.meta.url)), '--once', '--dry-run'], {
        env: { ...process.env, HOME: root, USERPROFILE: root,
          AGENTMEMORY_KEEPER_STATE_DIR: join(root, 'state'),
          AGENTMEMORY_URL: 'http://127.0.0.1:1' },
        timeout: 10000, encoding: 'utf8', windowsHide: true,
      });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /--once: exiting after initial scan/);
  } finally {
    assert.ok(resolve(root).startsWith(resolve(tmpdir()) + sep));
    await rm(root, { recursive: true, force: true });
  }
});
