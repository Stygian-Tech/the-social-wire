import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';

export class VerificationError extends Error {
  constructor(message, retryable = false) { super(message); this.retryable = retryable; }
}
const fail = message => { throw new VerificationError(message); };
const pending = message => { throw new VerificationError(message, true); };
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);

// Every request is GET. Missing propagation evidence may be retried; rejected
// evidence is terminal and must never fall back to an older successful check.
export async function verifyOnce(api, repository, mergeSHA) {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) || !sha(mergeSHA)) fail('Invalid repository or pushed commit');
  const sameRepo = value => typeof value === 'string' && value.toLowerCase() === repository.toLowerCase();
  const prefix = `/repos/${repository}`;
  const associated = await api(`${prefix}/commits/${mergeSHA}/pulls?per_page=100`);
  if (!Array.isArray(associated) || associated.length >= 100) fail('Unbounded or invalid associated pull requests');
  const candidates = associated.filter(pr => pr.base?.ref === 'main' && sameRepo(pr.base?.repo?.full_name) && pr.merge_commit_sha === mergeSHA && pr.merged_at);
  if (!candidates.length) pending('Merged main pull request not visible yet');
  if (candidates.length !== 1) fail('Ambiguous merged main pull request');
  const number = candidates[0].number;
  if (!Number.isSafeInteger(number) || number < 1) fail('Invalid pull request number');
  const pr = await api(`${prefix}/pulls/${number}`);
  if (pr.number !== number || pr.merged !== true || pr.state !== 'closed' || !pr.merged_at || pr.base?.ref !== 'main' || !sameRepo(pr.base?.repo?.full_name) || !sameRepo(pr.head?.repo?.full_name) || pr.merge_commit_sha !== mergeSHA || !sha(pr.head?.sha)) fail('Pull request does not prove this exact main merge');
  const headSHA = pr.head.sha;
  const checks = await api(`${prefix}/commits/${headSHA}/check-runs?filter=latest&per_page=100`);
  if (!Array.isArray(checks.check_runs) || !Number.isSafeInteger(checks.total_count) || checks.total_count < 0 || checks.total_count >= 100) fail('Unbounded or invalid check evidence');
  const relevant = checks.check_runs.filter(check => check.name === 'CI — Required' && check.app?.slug === 'github-actions');
  if (!relevant.length) pending('Required head check not visible yet');
  relevant.sort((a, b) => b.id - a.id);
  const check = relevant[0];
  if (!Number.isSafeInteger(check.id) || check.head_sha !== headSHA) fail('Required check is not for this exact pull request head');
  if (check.status !== 'completed') pending('Latest required head check is still pending');
  if (check.conclusion !== 'success') fail('Latest required head check did not succeed');
  let details;
  try { details = new URL(check.details_url); } catch { fail('Missing trusted workflow provenance'); }
  const escaped = repository.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = details.pathname.match(new RegExp(`^/${escaped}/actions/runs/([0-9]+)(?:/job/[0-9]+)?/?$`, 'i'));
  if (details.protocol !== 'https:' || details.hostname !== 'github.com' || details.username || details.password || details.search || details.hash || !match) fail('Untrusted workflow provenance');
  const runID = Number(match[1]);
  if (!Number.isSafeInteger(runID) || runID < 1) fail('Invalid workflow run');
  const run = await api(`${prefix}/actions/runs/${runID}`);
  if (run.id !== runID || run.path !== '.github/workflows/ci.yml' || run.event !== 'pull_request' || run.head_sha !== headSHA || !sameRepo(run.repository?.full_name) || !Number.isSafeInteger(run.run_attempt) || run.run_attempt < 1 || !Number.isSafeInteger(run.check_suite_id) || run.check_suite_id !== check.check_suite?.id) fail('Required check lacks exact CI pull request provenance');
  if (run.status !== 'completed') pending('Exact CI workflow run is still pending');
  if (run.conclusion !== 'success') fail('Exact CI workflow run did not succeed');
  const jobs = await api(`${prefix}/actions/runs/${runID}/attempts/${run.run_attempt}/jobs?per_page=100`);
  if (!Array.isArray(jobs.jobs) || !Number.isSafeInteger(jobs.total_count) || jobs.total_count < 0 || jobs.total_count >= 100) fail('Unbounded or invalid workflow jobs');
  const requiredJobs = jobs.jobs.filter(job => job.name === 'CI — Required' && job.check_run_url === `https://api.github.com${prefix}/check-runs/${check.id}`);
  const changesJobs = jobs.jobs.filter(job => job.name === 'Detect Changed Paths');
  if (requiredJobs.length !== 1 || changesJobs.length !== 1) fail('Exact required workflow jobs missing or ambiguous');
  for (const job of [requiredJobs[0], changesJobs[0]]) {
    if (job.run_id !== runID || job.run_attempt !== run.run_attempt || job.head_sha !== headSHA || job.status !== 'completed' || job.conclusion !== 'success' || !Number.isSafeInteger(job.id)) fail('Workflow job lacks exact successful attempt provenance');
  }
  const logs = await api(`${prefix}/actions/jobs/${changesJobs[0].id}/logs`, { text: true });
  const receipt = parseReceipt(logs);
  const expected = { runID, runAttempt: run.run_attempt, prNumber: number, baseRef: 'main', headSHA, repository };
  if (Object.keys(receipt).length !== Object.keys(expected).length || Object.entries(expected).some(([key, value]) => receipt[key] !== value)) fail('Exact CI pull request receipt mismatch');
  const mergedCommit = await api(`${prefix}/git/commits/${mergeSHA}`);
  const headCommit = await api(`${prefix}/git/commits/${headSHA}`);
  if (mergedCommit.sha !== mergeSHA || headCommit.sha !== headSHA || !sha(mergedCommit.tree?.sha) || mergedCommit.tree.sha !== headCommit.tree?.sha) fail('Merged source tree differs from the validated pull request head');
  return { prNumber: number, mergeSHA, headSHA, treeSHA: mergedCommit.tree.sha, runID };
}

export async function verifyMergedCommit(api, repository, mergeSHA, { attempts = 8, delayMS = 5000, sleep = ms => new Promise(resolve => setTimeout(resolve, ms)) } = {}) {
  if (!Number.isInteger(attempts) || attempts < 1 || attempts > 8 || !Number.isInteger(delayMS) || delayMS < 0 || delayMS > 5000) fail('Invalid retry bounds');
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try { return await verifyOnce(api, repository, mergeSHA); }
    catch (error) {
      if (!(error instanceof VerificationError) || !error.retryable || attempt === attempts) throw error;
      await sleep(delayMS);
    }
  }
}

export function receiptFromEvent(event, env) {
  const pr = event.pull_request;
  const receipt = { runID: Number(env.GITHUB_RUN_ID), runAttempt: Number(env.GITHUB_RUN_ATTEMPT), prNumber: pr?.number, baseRef: pr?.base?.ref, headSHA: pr?.head?.sha, repository: env.GITHUB_REPOSITORY };
  if (!Number.isSafeInteger(receipt.runID) || receipt.runID < 1 || !Number.isSafeInteger(receipt.runAttempt) || receipt.runAttempt < 1 || !Number.isSafeInteger(receipt.prNumber) || receipt.prNumber < 1 || !sha(receipt.headSHA) || !['main', 'dev'].includes(receipt.baseRef) || pr.base?.repo?.full_name !== receipt.repository) fail('Invalid trusted PR receipt context');
  return receipt;
}

export function parseReceipt(logs) {
  if (typeof logs !== 'string' || Buffer.byteLength(logs) > 262144) fail('Invalid or oversized CI receipt logs');
  const matches = logs.split(/\r?\n/).map(line => line.match(/^(?:\d{4}-\d{2}-\d{2}T[0-9:.]+Z\s+)?CI_PR_RECEIPT (\{.*\})$/)).filter(Boolean);
  if (matches.length !== 1) fail('Missing or ambiguous immutable CI PR receipt');
  let receipt;
  try { receipt = JSON.parse(matches[0][1]); } catch { fail('Invalid CI PR receipt JSON'); }
  if (!receipt || Array.isArray(receipt) || typeof receipt !== 'object') fail('Invalid CI PR receipt');
  return receipt;
}

async function boundedText(response, maximumBytes) {
  if (response.body?.getReader) {
    const reader = response.body.getReader(), chunks = []; let length = 0;
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        length += value.byteLength;
        if (length > maximumBytes) { await reader.cancel(); fail('GitHub evidence exceeds byte limit'); }
        chunks.push(Buffer.from(value));
      }
    } finally { reader.releaseLock(); }
    return Buffer.concat(chunks).toString('utf8');
  }
  const text = await response.text();
  if (Buffer.byteLength(text) > maximumBytes) fail('GitHub evidence exceeds byte limit');
  return text;
}

// This version retains merge_commit_sha; newer API shapes omit the exact merge
// identity needed by this gate. Missing proof must remain a rejection.
export function githubReadAPI(token, { fetcher = fetch, deadlineMS = Date.now() + 120000 } = {}) {
  if (!token) fail('Missing GitHub read token');
  return async (path, { text = false } = {}) => {
    const remaining = deadlineMS - Date.now();
    if (remaining <= 0) fail('Merge verification deadline exhausted');
    const signal = AbortSignal.timeout(Math.min(10000, remaining));
    let response;
    try {
      response = await fetcher(`https://api.github.com${path}`, { method: 'GET', redirect: 'manual', headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`, 'X-GitHub-Api-Version': '2022-11-28' }, signal });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        if (!text || !/^\/repos\/[^/]+\/[^/]+\/actions\/jobs\/[0-9]+\/logs$/.test(path)) fail('Unexpected GitHub evidence redirect');
        let target; try { target = new URL(response.headers.get('location')); } catch { fail('Invalid GitHub logs redirect'); }
        if (target.protocol !== 'https:' || target.username || target.password || target.hash || !/^(?:productionresults[a-z0-9]*\.blob\.core\.windows\.net|[a-z0-9.-]+\.actions\.githubusercontent\.com)$/.test(target.hostname)) fail('Untrusted GitHub logs redirect');
        // Signed job-log URLs receive no GitHub token, and cannot redirect again.
        response = await fetcher(target.href, { method: 'GET', redirect: 'error', signal });
      }
    } catch (error) { if (error instanceof VerificationError) throw error; pending('GitHub read unavailable'); }
    if (response.status === 404 || response.status >= 500) pending('GitHub evidence temporarily unavailable');
    if (!response.ok) fail(`GitHub read rejected (${response.status})`);
    const body = await boundedText(response, text ? 262144 : 2097152);
    if (text) return body;
    try { return JSON.parse(body); } catch { fail('Invalid GitHub evidence response'); }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv[2] === '--receipt') {
      if (process.env.GITHUB_EVENT_NAME === 'pull_request') console.log('CI_PR_RECEIPT ' + JSON.stringify(receiptFromEvent(JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, 'utf8')), process.env)));
    } else {
      if (process.env.GITHUB_EVENT_NAME !== 'push' || process.env.GITHUB_REF !== 'refs/heads/main') fail('Only main push events may validate a deployment');
      const evidence = await verifyMergedCommit(githubReadAPI(process.env.GITHUB_TOKEN), process.env.GITHUB_REPOSITORY, process.env.GITHUB_SHA);
      console.log(`Validated main merge ${evidence.mergeSHA}, PR #${evidence.prNumber}, CI run ${evidence.runID}, source tree ${evidence.treeSHA}`);
    }
  } catch (error) {
    console.error(error instanceof VerificationError ? error.message : 'Merge verification failed');
    process.exitCode = 1;
  }
}
