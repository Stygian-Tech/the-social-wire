import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rename, rm } from 'node:fs/promises';
import { tmpdir, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { PDS } from '@atproto/pds';
import { Database, PlcServer } from '@did-plc/server';
import { Secp256k1Keypair } from '@atproto/crypto';
import { verifyReadStateCAR } from './source/proof';
import { CHUNK_COLLECTION as CHUNK, MANIFEST_COLLECTION as MANIFEST, ReadStateError,
  collectReadStateGarbage, ensureV2Generation, loadV2Generation, commitIntent, V2ReadStateOutbox,
  type ReadStateGarbageCollectionTransport, type ReadStateGarbageCollectionState,
  type ReadStateGarbageCollectionStore, type Reference, type V2Manifest, type OutboxStore, type OutboxState,
} from './source/core';

// Fail closed: fixture must run in an unnetworked container, not against a supplied service.
assert.equal(process.env.TSW_REFERENCE_PDS_ISOLATED, '1');
assert.ok(Object.values(networkInterfaces()).flat().every(address => !address || address.internal));
const directory = await mkdtemp(join(tmpdir(), 'tsw-reference-pds-'));
const plcURL = 'http://localhost:2582', pdsURL = 'http://localhost:2583';
const rotationKey = await Secp256k1Keypair.create({ exportable: true });
const plc = PlcServer.create({ db: Database.mock(), port: 2582 });
const config = {
  devMode: true, port: 2583, hostname: 'localhost', dataDirectory: join(directory, 'pds'),
  blobstoreDiskLocation: join(directory, 'blobs'), didPlcUrl: plcURL,
  plcRotationKeyK256PrivateKeyHex: Buffer.from(await rotationKey.export()).toString('hex'),
  recoveryDidKey: (await Secp256k1Keypair.create()).did(),
  adminPassword: 'fixture-only-no-network', jwtSecret: 'fixture-only-jwt-no-network',
  serviceHandleDomains: ['.test'], inviteRequired: false, disableSsrfProtection: true,
  bskyAppViewUrl: 'http://localhost:2599', bskyAppViewDid: 'did:example:invalid',
};
let pds: PDS | undefined;
const deadline = setTimeout(() => { console.error('Fixture exceeded its 90-second execution budget'); process.exit(1); }, 90_000).unref();
let passed = 0;
const results: { name: string; elapsedMs: number }[] = [];
const intent = (actionId: string) => ({ actionId, state: 'read' as const, actedAt: '2026-09-08T00:00:00Z', selection: 'exact' as const, subjectUris: [`at://did:plc:article/app.example.article/${actionId}`] });
async function json(url: string, options?: RequestInit) {
  const response = await fetch(url, options); const body = await response.json() as any;
  if (!response.ok) throw Object.assign(new Error(`${response.status}:${body.error}`), { status: response.status, code: body.error });
  return body;
}
class Repo implements ReadStateGarbageCollectionTransport {
  batches = 0; loseResponse = false; beforeAtomic?: () => Promise<void>;
  constructor(readonly viewerDid: string, readonly token: string, readonly signingKey: string) {}
  async request(method: string, params: any, write = false) {
    return json(`${pdsURL}/xrpc/${method}${write ? '' : `?${new URLSearchParams(params)}`}`, {
      method: write ? 'POST' : 'GET', headers: { authorization: `Bearer ${this.token}`, ...(write ? { 'content-type': 'application/json' } : {}) },
      ...(write ? { body: JSON.stringify(params) } : {}),
    });
  }
  async getRecord(collection: string, rkey: string, cid?: string) {
    try { return await this.request('com.atproto.repo.getRecord', { repo: this.viewerDid, collection, rkey, ...(cid ? { cid } : {}) }); }
    catch (error: any) { if (error.code === 'RecordNotFound') return null; throw error; }
  }
  async putRecord(collection: string, rkey: string, record: any, swapRecord: string | null) {
    try { const result = await this.request('com.atproto.repo.putRecord', { repo: this.viewerDid, collection, rkey, record, swapRecord, validate: false }, true); return { uri: result.uri, cid: result.cid }; }
    catch (error: any) { if (error.code === 'InvalidSwap') throw new ReadStateError('conflict'); throw error; }
  }
  async verifiedRecord(collection: string, rkey: string) {
    const response = await fetch(`${pdsURL}/xrpc/com.atproto.sync.getRecord?${new URLSearchParams({ did: this.viewerDid, collection, rkey })}`);
    assert.equal(response.status, 200, 'Reference PDS must return an actual signed CAR proof');
    return verifyReadStateCAR(new Uint8Array(await response.arrayBuffer()), this.viewerDid, collection, rkey, this.signingKey);
  }
  async listChunks(cursor?: string) {
    return this.request('com.atproto.repo.listRecords', { repo: this.viewerDid, collection: CHUNK, limit: '100', ...(cursor ? { cursor } : {}) });
  }
  async atomicCollect(baseCommit: string, manifest: V2Manifest, candidates: Reference[]) {
    await this.beforeAtomic?.();
    const result = await this.request('com.atproto.repo.applyWrites', { repo: this.viewerDid, swapCommit: baseCommit, validate: false,
      writes: [{ $type: 'com.atproto.repo.applyWrites#update', collection: MANIFEST, rkey: 'self', value: manifest },
        ...candidates.map(ref => ({ $type: 'com.atproto.repo.applyWrites#delete', collection: CHUNK, rkey: ref.uri.split('/').at(-1) }))],
    }, true);
    this.batches++;
    if (this.loseResponse) { this.loseResponse = false; throw new Error('Injected lost HTTP response after real successful transaction'); }
    return { commitCid: result.commit.cid };
  }
}
class Ledger implements ReadStateGarbageCollectionStore {
  constructor(readonly viewerDid: string, readonly path: string) {}
  async read() { try { return JSON.parse(await readFile(this.path, 'utf8')); } catch (error: any) { if (error.code !== 'ENOENT') throw error; return { viewerDid: this.viewerDid, candidates: [] }; } }
  async write(state: ReadStateGarbageCollectionState) { await writeFile(`${this.path}.next`, JSON.stringify(state)); await rename(`${this.path}.next`, this.path); }
}
class QueueStore implements OutboxStore {
  state: OutboxState;
  constructor(viewerDid: string) { this.state = { viewerDid, entries: [] }; }
  async read() { return structuredClone(this.state); }
  async update(_viewer: string, apply: (state: OutboxState) => OutboxState) { this.state = apply(structuredClone(this.state)); return structuredClone(this.state); }
}
async function account(name: string) {
  const session = await json(`${pdsURL}/xrpc/com.atproto.server.createAccount`, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ handle: `${name}.test`, email: `${name}@example.invalid`, password: 'local-fixture-password-only' }) });
  const doc = await json(`${plcURL}/${session.did}/data`);
  const signingKey = doc.verificationMethods.atproto;
  assert.ok(signingKey.startsWith('did:key:'));
  const repo = new Repo(session.did, session.accessJwt, signingKey);
  await repo.putRecord(MANIFEST, 'self', { $type: MANIFEST, version: 1, generation: 'migration-confirmed-fixture', lastSequence: 0 }, null);
  await commitIntent(repo, intent('legacy'));
  await ensureV2Generation(repo, async () => {});
  const queue = new V2ReadStateOutbox(new QueueStore(repo.viewerDid), repo, async () => {}, async (_key, operation) => operation());
  await queue.enqueue(intent('device')); assert.equal(await queue.flushOnce(), true);
  const generation = await loadV2Generation(repo);
  assert.ok(generation.manifest.stateHead && generation.manifest.devicesHead && generation.manifest.legacyReceiptsHead);
  const orphan = await repo.putRecord(CHUNK, 'orphan', { $type: CHUNK, version: 1, operations: [{ ...intent('orphan'), sequence: 1 }] }, null);
  const ledger = new Ledger(repo.viewerDid, join(directory, `${name}-ledger.json`));
  const confirm = async (ref: Reference) => assert.equal((await repo.getRecord(MANIFEST, 'self'))?.cid, ref.cid);
  const run = (hour: number, store: Ledger = ledger) => collectReadStateGarbage(repo, store, confirm,
    { enabled: true, now: hour * 3600_000, clock: { epoch: 'controlled-fixture-clock', monotonic: hour * 3600_000 } });
  for (let hour = 0; hour < 24; hour += 6) assert.equal((await run(hour)).deleted, 0);
  return { repo, ledger, orphan, run, generation };
}
async function test(name: string, action: () => Promise<void>) {
  const start = performance.now(); await action(); passed++; results.push({ name, elapsedMs: Math.round(performance.now() - start) }); console.log(`PASS ${name}`);
}
try {
  await mkdir(config.dataDirectory, { recursive: true }); await plc.start(); pds = await PDS.fromEnv(config); await pds.start();
  await test('GC-first real atomic commit invalidates paused manifest writer and preserves all three roots', async () => {
    const { repo, run, generation, orphan } = await account('gcfirst');
    assert.ok((await run(24)).deleted >= 1);
    assert.equal(await repo.getRecord(CHUNK, 'orphan'), null);
    await assert.rejects(repo.putRecord(MANIFEST, 'self', { ...generation.manifest, generation: 'paused-writer', stateHead: orphan }, generation.record.cid), /conflict/);
    const after = await loadV2Generation(repo);
    assert.deepEqual(after.fragments, generation.fragments); assert.deepEqual(after.devices, generation.devices); assert.deepEqual(after.legacyReceipts, generation.legacyReceipts);
    for (const ref of after.references) assert.equal((await repo.verifiedRecord(CHUNK, ref.uri.split('/').at(-1)!)).record?.cid, ref.cid);
  });
  await test('Writer-first real swapCommit conflict rolls back both singleton update and every delete', async () => {
    const { repo, run, generation } = await account('writerfirst'); let writerCid = '';
    const chunksBefore = (await repo.listChunks()).records;
    repo.beforeAtomic = async () => { repo.beforeAtomic = undefined;
      writerCid = (await repo.putRecord(MANIFEST, 'self', { ...generation.manifest, generation: 'winning-writer', revision: generation.manifest.revision + 1 }, generation.record.cid)).cid; };
    await assert.rejects(run(24), /InvalidSwap/); assert.equal(repo.batches, 0);
    assert.ok(await repo.getRecord(CHUNK, 'orphan')); assert.equal((await repo.getRecord(MANIFEST, 'self'))?.cid, writerCid);
    assert.deepEqual((await repo.listChunks()).records, chunksBefore);
  });
  await test('Candidate replacement after signed proof rejects the real atomic delete', async () => {
    const { repo, run, orphan, generation } = await account('proofrace'); let replacementCid = '';
    repo.beforeAtomic = async () => { repo.beforeAtomic = undefined;
      replacementCid = (await repo.putRecord(CHUNK, 'orphan', { $type: CHUNK, version: 1, operations: [{ ...intent('proofrace'), sequence: 1 }] }, orphan.cid)).cid; };
    await assert.rejects(run(24), /InvalidSwap/);
    assert.equal(repo.batches, 0); assert.equal((await repo.getRecord(CHUNK, 'orphan'))?.cid, replacementCid);
    assert.equal((await repo.getRecord(MANIFEST, 'self'))?.cid, generation.record.cid);
  });
  await test('Same-rkey replacement resets observed grace on the real repository', async () => {
    const { repo, run, orphan } = await account('replacement');
    const replacement = await repo.putRecord(CHUNK, 'orphan', { $type: CHUNK, version: 1, operations: [{ ...intent('replacement'), sequence: 1 }] }, orphan.cid);
    await run(24); assert.equal((await repo.getRecord(CHUNK, 'orphan'))?.cid, replacement.cid);
    for (const hour of [30, 36, 42]) { await run(hour); assert.ok(await repo.getRecord(CHUNK, 'orphan')); }
    assert.equal((await run(48)).deleted, 1); assert.equal(await repo.getRecord(CHUNK, 'orphan'), null);
  });
  await test('Lost successful response and PDS restart recover from signed proofs without replaying deletes', async () => {
    const { repo, run, ledger, generation } = await account('restart'); repo.loseResponse = true;
    await assert.rejects(run(24), /Injected lost HTTP response/); assert.ok((await ledger.read()).pending); const batches = repo.batches;
    await pds!.destroy(); pds = await PDS.fromEnv(config); await pds.start();
    const reloaded = new Ledger(repo.viewerDid, ledger.path); assert.equal((await run(24, reloaded)).deleted, 0);
    assert.equal(repo.batches, batches); assert.equal((await reloaded.read()).pending, undefined);
    const after = await loadV2Generation(repo); assert.deepEqual(after.fragments, generation.fragments);
    assert.deepEqual(after.devices, generation.devices); assert.deepEqual(after.legacyReceipts, generation.legacyReceipts);
    for (const ref of after.references) assert.equal((await repo.verifiedRecord(CHUNK, ref.uri.split('/').at(-1)!)).record?.cid, ref.cid);
  });
  await writeFile('/fixture/results.json', JSON.stringify({ referencePds: '0.5.31', node: process.version, isolatedNetwork: true,
    transactions: 'actual HTTP against official SQLite PDS', planner: 'unmodified repository source snapshot',
    proof: 'unmodified Web verifier source snapshot', grace: 'controlled clocks, not a real 24-hour soak',
    appview: 'confirmation callback checks singleton only; hosted AppView parity is a separate gate', passed, results }, null, 2));
  console.log(`COMPLETE ${passed} real-reference-PDS conformance scenarios`);
} finally { clearTimeout(deadline); await pds?.destroy(); await plc.destroy(); await rm(directory, { recursive: true, force: true }); }
