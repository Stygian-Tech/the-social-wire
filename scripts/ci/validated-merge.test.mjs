import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyOnce, verifyMergedCommit, githubReadAPI, VerificationError, parseReceipt, receiptFromEvent } from './validated-merge.mjs';
const repository = 'owner/repo', merge = 'a'.repeat(40), head = 'b'.repeat(40), tree = 'c'.repeat(40);
function fixture() {
  const base = { ref: 'main', repo: { full_name: repository } };
  const pr = { number: 7, merged: true, state: 'closed', merged_at: '2026-10-07T00:00:00Z', merge_commit_sha: merge, base, head: { sha: head, repo: { full_name: repository } } };
  const check = { check_suite: { id: 100 }, id: 19, name: 'CI — Required', app: { slug: 'github-actions' }, head_sha: head, status: 'completed', conclusion: 'success', details_url: 'https://github.com/owner/repo/actions/runs/31/job/19' };
  const run = { check_suite_id: 100, run_attempt: 1, id: 31, path: '.github/workflows/ci.yml', event: 'pull_request', head_sha: head, status: 'completed', conclusion: 'success', repository: { full_name: repository }, pull_requests: [{ number: 7 }] };
  const data = { [`/repos/${repository}/commits/${merge}/pulls?per_page=100`]: [pr], [`/repos/${repository}/pulls/7`]: pr, [`/repos/${repository}/commits/${head}/check-runs?filter=latest&per_page=100`]: { total_count: 1, check_runs: [check] }, [`/repos/${repository}/actions/runs/31`]: run, [`/repos/${repository}/git/commits/${merge}`]: { sha: merge, tree: { sha: tree } }, [`/repos/${repository}/git/commits/${head}`]: { sha: head, tree: { sha: tree } } };
  const receipt = { runID: 31, runAttempt: 1, prNumber: 7, baseRef: 'main', headSHA: head, repository };
  const job = { run_id: 31, run_attempt: 1, head_sha: head, status: 'completed', conclusion: 'success' };
  data[`/repos/${repository}/actions/runs/31/attempts/1/jobs?per_page=100`] = { total_count: 2, jobs: [{ ...job, id: 80, name: 'Detect Changed Paths' }, { ...job, id: 81, name: 'CI — Required', check_run_url: `https://api.github.com/repos/${repository}/check-runs/19` }] };
  data[`/repos/${repository}/actions/jobs/80/logs`] = '2026-10-07T00:00:00.000Z CI_PR_RECEIPT ' + JSON.stringify(receipt);
  return { pr, check, run, data, api: async path => { assert.ok(path in data, path); return structuredClone(data[path]); } };
}
test('validates exact main merge and tree without executing source or writing GitHub', async () => { const f = fixture(); assert.equal((await verifyOnce(f.api, repository, merge)).prNumber, 7); });
for (const [name, alter] of [
  ['wrong base', f => f.pr.base.ref = 'dev'],
  ['wrong repo', f => f.pr.base.repo.full_name = 'other/repo'],
  ['unmerged PR', f => f.pr.merged = false],
  ['wrong merged SHA', f => f.pr.merge_commit_sha = head],
  ['fork PR', f => f.pr.head.repo.full_name = 'fork/repo'],
  ['wrong check head', f => f.check.head_sha = merge],
  ['failed check', f => f.check.conclusion = 'failure'],
  ['neutral check', f => f.check.conclusion = 'neutral'],
  ['skipped check', f => f.check.conclusion = 'skipped'],
  ['spoofed workflow URL', f => f.check.details_url = 'https://attacker.example/owner/repo/actions/runs/31'],
  ['wrong workflow', f => f.run.path = '.github/workflows/other.yml'],
  ['wrong event', f => f.run.event = 'workflow_dispatch'],
  ['wrong run SHA', f => f.run.head_sha = merge],
  ['failed overall run', f => f.run.conclusion = 'failure'],
  ['different merged tree', f => f.data[`/repos/${repository}/git/commits/${merge}`].tree.sha = head],
]) test(`rejects ${name}`, async () => { const f = fixture(); alter(f); await assert.rejects(verifyOnce(f.api, repository, merge), VerificationError); });
test('never falls back to older success after newest failure', async () => { const f = fixture(); const old = structuredClone(f.check); f.check.id++; f.check.conclusion = 'failure'; f.data[`/repos/${repository}/commits/${head}/check-runs?filter=latest&per_page=100`].check_runs.push(old); let sleeps = 0; await assert.rejects(verifyMergedCommit(f.api, repository, merge, { sleep: async () => sleeps++ }), /did not succeed/); assert.equal(sleeps, 0); });
test('bounded propagation retries allow missing evidence then exact success', async () => { const f = fixture(); let reads = 0, sleeps = 0; const api = async path => path.includes('/pulls?') && reads++ < 2 ? [] : f.api(path); await verifyMergedCommit(api, repository, merge, { attempts: 3, sleep: async () => sleeps++ }); assert.equal(sleeps, 2); });
test('missing evidence exhausts retry budget', async () => { let reads = 0, sleeps = 0; await assert.rejects(verifyMergedCommit(async () => { reads++; return []; }, repository, merge, { attempts: 3, sleep: async () => sleeps++ }), /not visible/); assert.equal(reads, 3); assert.equal(sleeps, 2); });
test('HTTP adapter makes GET-only authenticated reads and denies auth failure', async () => { let request; const api = githubReadAPI('test-token', { fetcher: async (url, options) => { request = { url, options }; return { ok: true, status: 200, text: async () => JSON.stringify({ ok: true }) }; } }); await api('/repos/owner/repo'); assert.equal(request.options.method, 'GET'); assert.equal(request.options.headers['X-GitHub-Api-Version'], '2022-11-28'); assert.equal(request.url, 'https://api.github.com/repos/owner/repo'); const denied = githubReadAPI('test-token', { fetcher: async () => ({ ok: false, status: 403 }) }); await assert.rejects(denied('/repos/owner/repo'), e => e.retryable === false); });
test('deadline exhaustion does not make another API request', async () => { let calls = 0; const api = githubReadAPI('test-token', { deadlineMS: 0, fetcher: async () => calls++ }); await assert.rejects(api('/repos/owner/repo'), /deadline/); assert.equal(calls, 0); });
test('pending newest required check never uses older successful check', async () => { const f = fixture(); const old = structuredClone(f.check); f.check.id++; f.check.status = 'in_progress'; f.check.conclusion = null; f.data[`/repos/${repository}/commits/${head}/check-runs?filter=latest&per_page=100`].check_runs.push(old); let sleeps = 0; await assert.rejects(verifyMergedCommit(f.api, repository, merge, { attempts: 2, sleep: async () => sleeps++ }), /pending/); assert.equal(sleeps, 1); });
test('rejects ambiguous matching merge PRs', async () => { const f = fixture(); f.data[`/repos/${repository}/commits/${merge}/pulls?per_page=100`].push(structuredClone(f.pr)); await assert.rejects(verifyOnce(f.api, repository, merge), /Ambiguous/); });
test('rejects truncated evidence instead of trusting first page', async () => { const f = fixture(); f.data[`/repos/${repository}/commits/${head}/check-runs?filter=latest&per_page=100`].total_count = 100; await assert.rejects(verifyOnce(f.api, repository, merge), /Unbounded/); });
test('does not accept checks from another app', async () => { const f = fixture(); f.check.app.slug = 'other-app'; await assert.rejects(verifyOnce(f.api, repository, merge), /not visible/); });

test('closed PR empty GitHub association arrays use exact immutable receipt', async () => { const f = fixture(); f.run.pull_requests = []; await verifyOnce(f.api, repository, merge); });
test('mismatched receipt rejects a different PR on the same head', async () => { const f = fixture(); f.run.pull_requests = []; f.data[`/repos/${repository}/actions/jobs/80/logs`] = f.data[`/repos/${repository}/actions/jobs/80/logs`].replace('"prNumber":7', '"prNumber":8'); await assert.rejects(verifyOnce(f.api, repository, merge), /receipt mismatch/); });
test('rejects duplicated receipt lines', () => { const line = 'CI_PR_RECEIPT {}'; assert.throws(() => parseReceipt(line + '\n' + line), /ambiguous/); });
test('rejects oversized job logs', () => { assert.throws(() => parseReceipt('x'.repeat(262145)), /oversized/); });
test('rejects receipt job from another run attempt', async () => { const f = fixture(); f.data[`/repos/${repository}/actions/runs/31/attempts/1/jobs?per_page=100`].jobs[0].run_attempt = 2; await assert.rejects(verifyOnce(f.api, repository, merge), /attempt provenance/); });
test('rejects another check suite despite a plausible details URL', async () => { const f = fixture(); f.run.check_suite_id++; await assert.rejects(verifyOnce(f.api, repository, merge), /provenance/); });
test('receipt construction uses only validated GitHub metadata', () => { const f = fixture(); assert.equal(receiptFromEvent({ pull_request: f.pr, privateBody: 'do not emit' }, { GITHUB_RUN_ID: '31', GITHUB_RUN_ATTEMPT: '1', GITHUB_REPOSITORY: repository }).prNumber, 7); });
test('signed log redirect never receives the GitHub token', async () => { const requests = []; const api = githubReadAPI('test-token', { fetcher: async (url, options) => { requests.push({ url, options }); return requests.length === 1 ? { status: 302, headers: new Headers({ location: 'https://productionresultssa5.blob.core.windows.net/log.txt?sig=private' }) } : { ok: true, status: 200, text: async () => 'CI_PR_RECEIPT {}' }; } }); await api('/repos/owner/repo/actions/jobs/80/logs', { text: true }); assert.equal(requests[0].options.headers.Authorization, 'Bearer test-token'); assert.equal(requests[1].options.headers, undefined); assert.equal(requests[1].options.redirect, 'error'); });
test('rejects unexpected log redirect hosts before requesting them', async () => { let calls = 0; const api = githubReadAPI('test-token', { fetcher: async () => { calls++; return { status: 302, headers: new Headers({ location: 'https://attacker.example/logs' }) }; } }); await assert.rejects(api('/repos/owner/repo/actions/jobs/80/logs', { text: true }), /Untrusted/); assert.equal(calls, 1); });
test('streamed logs exceeding the byte cap are cancelled', async () => { let cancelled = false; const body = new ReadableStream({ start(controller) { controller.enqueue(new Uint8Array(262145)); }, cancel() { cancelled = true; } }); const api = githubReadAPI('test-token', { fetcher: async () => new Response(body) }); await assert.rejects(api('/repos/owner/repo/actions/jobs/80/logs', { text: true }), /byte limit/); assert.equal(cancelled, true); });
test('missing immutable receipt never substitutes API association metadata', async () => { const f = fixture(); f.data[`/repos/${repository}/actions/jobs/80/logs`] = 'ordinary successful job output'; await assert.rejects(verifyOnce(f.api, repository, merge), /immutable CI PR receipt/); });

test('new API associated PR shape omitting merge_commit_sha fails closed', async () => { const f = fixture(); delete f.pr.merge_commit_sha; await assert.rejects(verifyOnce(f.api, repository, merge), /not visible/); });
test('new API full PR shape omitting merge_commit_sha cannot pass exact merge proof', async () => { const f = fixture(); f.data[`/repos/${repository}/commits/${merge}/pulls?per_page=100`] = [structuredClone(f.pr)]; delete f.pr.merge_commit_sha; await assert.rejects(verifyOnce(f.api, repository, merge), /exact main merge/); });
