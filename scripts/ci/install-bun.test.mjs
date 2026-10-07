import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

function install(firstMessage, firstStatus, secondStatus = 0) {
  const root = mkdtempSync(join(tmpdir(), 'bun-install-test-'));
  const calls = join(root, 'calls');
  const existingCache = join(root, 'existing-cache-sentinel');
  writeFileSync(existingCache, 'preserve');
  writeFileSync(join(root, 'bun'), `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> "$CALLS"\nif [ "$(wc -l < "$CALLS")" -eq 1 ]; then\n printf '%s\\n' "$FIRST_MESSAGE"\n exit "$FIRST_STATUS"\nfi\nexit "$SECOND_STATUS"\n`, { mode: 0o755 });
  const result = spawnSync('bash', [resolve('scripts/ci/install-bun.sh')], { env: { ...process.env, PATH: `${root}:${process.env.PATH}`, RUNNER_TEMP: root, CALLS: calls, FIRST_MESSAGE: firstMessage, FIRST_STATUS: String(firstStatus), SECOND_STATUS: String(secondStatus) }, encoding: 'utf8' });
  const args = readFileSync(calls, 'utf8').trim().split('\n');
  const cacheDirectories = readdirSync(root).filter(name => name.startsWith('bun-install-cache.'));
  assert.equal(readFileSync(existingCache, 'utf8'), 'preserve');
  const logs = readdirSync(root).filter(name => name.startsWith('bun-install-log.'));
  rmSync(root, { recursive: true, force: true });
  return { ...result, args, cacheDirectories, logs };
}

test('success installs once with the frozen lockfile', () => {
  const result = install('', 0);
  assert.equal(result.status, 0);
  assert.deepEqual(result.args, ['install --frozen-lockfile']);
  assert.deepEqual(result.cacheDirectories, []);
  assert.deepEqual(result.logs, []);
});
test('known extraction failure retries once with a unique fresh cache', () => {
  const first = install('error: Fail extracting tarball for "next"', 1);
  const second = install('error: Fail extracting tarball for "next"', 1);
  for (const result of [first, second]) {
    assert.equal(result.status, 0);
    assert.equal(result.args.length, 2);
    assert.equal(result.args[0], 'install --frozen-lockfile');
    assert.match(result.args[1], /^install --frozen-lockfile --cache-dir \/.+\/bun-install-cache\.[^/]+$/);
    assert.equal(result.cacheDirectories.length, 1);
    assert.deepEqual(result.logs, []);
  }
  assert.notEqual(first.args[1], second.args[1]);
});
test('exhausted extraction retry preserves the failed exit status', () => {
  const result = install('error: Fail extracting tarball for "next"', 1, 42);
  assert.equal(result.status, 42);
  assert.equal(result.args.length, 2);
});
for (const message of ['error: lockfile had changes, but lockfile is frozen', 'error: Integrity check failed', 'error: checksum mismatch', 'error: network unavailable', 'error: Fail extracting tarball for "next"\nerror: network unavailable', 'unrelated text: Fail extracting tarball for next', 'error: Fail extracting tarball for "next"\nerror: Integrity check failed']) {
  test(`does not retry ${message}`, () => {
    const result = install(message, 23);
    assert.equal(result.status, 23);
    assert.equal(result.args.length, 1);
    assert.deepEqual(result.cacheDirectories, []);
  });
}
