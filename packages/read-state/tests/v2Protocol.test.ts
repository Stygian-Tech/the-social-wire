import { describe, expect, test } from "bun:test";
import { CHUNK_COLLECTION, MANIFEST_COLLECTION, V2ReadStateOutbox, compactV2Generation, ensureV2Generation,
  loadV2Generation, commitIntent, recordCID, validateManifest, validateV2Chunk, type V2Manifest } from "../src";
import { activatedRepository, Store, intent, lock, viewer, at } from "./fixture";

async function setup() {
  const repo = await activatedRepository(), store = new Store(); let now = 1000;
  const confirm = async () => {}; await ensureV2Generation(repo, confirm);
  const sharedLock = lock();
  return { repo, store, confirm, outbox: () => new V2ReadStateOutbox(store, repo, confirm, sharedLock, () => now, () => 0), advance: () => { now += 10_000; } };
}

describe("v2 canonical generations and durable receipts", () => {
  test("upgrade confirms complete v1 before pruning and advances the cross-version revision fence", async () => {
    const repo = await activatedRepository();
    await commitIntent(repo, intent("old")); await commitIntent(repo, intent("new", "unread"));
    const versions: unknown[] = [];
    const generation = await ensureV2Generation(repo, async () => { versions.push((repo.manifest().value as {version:number}).version); });
    expect(versions).toEqual([1, 2]); expect(generation.manifest.revision).toBe(3);
    expect(generation.manifest.lastSequence).toBe(2); expect(generation.fragments).toHaveLength(1);
    expect(generation.legacyReceipts.map(value => value.actionId)).toEqual(["old", "new"]);
    expect(() => validateManifest(generation.manifest, viewer)).toThrow();
    expect(generation.projection.resolve({uri:"at://article/a", authorDid:viewer, createdAt:at}).isRead).toBe(false);
  });
  test("unattempted tail replacement reuses its counter and restart keeps the installation identity", async () => {
    const {outbox} = await setup(); const first = outbox();
    await first.enqueue(intent("read")); await first.enqueue(intent("unread", "unread"));
    const queued = await first.snapshot(); expect(queued.entries.map(value => value.deviceCounter)).toEqual([1]);
    expect(queued.device?.nextCounter).toBe(2);
    const restarted = outbox(); expect((await restarted.snapshot()).device?.deviceId).toBe(queued.device?.deviceId);
    expect(await restarted.flushOnce()).toBe(true); const state = await restarted.snapshot();
    expect(state.entries).toHaveLength(0); expect(state.device?.acknowledgedCounter).toBe(1);
  });
  test("unknown success remains acknowledged after another device supersedes and compacts its state", async () => {
    const {repo,outbox,advance,confirm} = await setup(); const first = outbox(); await first.enqueue(intent("first"));
    repo.failAfterManifest = true; expect(await first.flushOnce()).toBe(false);
    const second = new V2ReadStateOutbox(new Store(),repo,confirm,lock());
    await second.enqueue(intent("later", "unread")); expect(await second.flushOnce()).toBe(true);
    await compactV2Generation(repo, confirm); const before = await loadV2Generation(repo);
    expect(before.fragments.map(value=>value.actionId)).toEqual(["later"]); expect(before.devices).toHaveLength(2);
    advance(); expect(await outbox().flushOnce()).toBe(true);
    const after = await loadV2Generation(repo); expect(after.manifest.lastSequence).toBe(2);
    expect(after.manifest.revision).toBe(before.manifest.revision); expect((await first.snapshot()).entries).toHaveLength(0);
  });
  test("an unverifiable receipt prefix preserves pending changes and performs no more writes", async () => {
    const {repo,outbox,advance,store} = await setup(); const queue = outbox(); await queue.enqueue(intent("first"));
    repo.failAfterManifest=true; expect(await queue.flushOnce()).toBe(false);
    await store.update(viewer,state=>({...state,device:{...state.device!,acknowledgedPrefixHash:"f".repeat(64)}}));
    const writes=repo.writes.length; advance(); expect(await outbox().flushOnce()).toBe(false);
    expect(repo.writes).toHaveLength(writes); expect((await queue.snapshot()).entries).toHaveLength(1);
    expect((await queue.snapshot()).lastError).toBe("conflicting_sequence");
  });
  test("a maintenance CAS conflict invalidates candidate uploads and deleted candidates are re-uploaded", async () => {
    const {repo,outbox} = await setup(); const queue=outbox(); await queue.enqueue(intent("first")); let raced=false,deleted=0;
    repo.beforePut=async collection=>{
      if(collection!==MANIFEST_COLLECTION||raced)return; raced=true;
      const live=await loadV2Generation(repo), reachable=new Set(live.references.map(value=>value.uri));
      for(const [key,record] of repo.records) if(key.startsWith(CHUNK_COLLECTION)&&!reachable.has(record.uri)){repo.records.delete(key);deleted++;}
      const value:V2Manifest={...live.manifest,generation:"maintenance",revision:live.manifest.revision+1};
      repo.records.set(`${MANIFEST_COLLECTION}/self`,{...live.record,value,cid:await recordCID(value)});
    };
    expect(await queue.flushOnce()).toBe(true); expect(deleted).toBeGreaterThan(0);
    const generation=await loadV2Generation(repo); expect(generation.manifest.lastSequence).toBe(1); expect(generation.manifest.revision).toBe(3);
  });
  test("a new opposite action while upload waits cannot replace an attempted prefix", async () => {
    const {repo,outbox}=await setup(); const queue=outbox(); await queue.enqueue(intent("first"));
    let entered!:()=>void,release!:()=>void; const waiting=new Promise<void>(resolve=>{entered=resolve;}); const gate=new Promise<void>(resolve=>{release=resolve;}); let paused=false;
    repo.beforePut=async collection=>{if(collection===CHUNK_COLLECTION&&!paused){paused=true;entered();await gate;}};
    const flushing=queue.flushOnce(); await waiting; await queue.enqueue(intent("second","unread"));
    expect((await queue.snapshot()).entries.map(value=>value.deviceCounter)).toEqual([1,2]); release();
    expect(await flushing).toBe(true); expect((await queue.snapshot()).entries.map(value=>value.intent.actionId)).toEqual(["second"]);
    expect(await queue.flushOnce()).toBe(true); expect((await loadV2Generation(repo)).manifest.lastSequence).toBe(2);
  });
  test("an old random-ID retry advances only its device receipt without repeating the legacy action", async () => {
    const repo=await activatedRepository(); await commitIntent(repo,intent("old")); const store=new Store();
    await store.update(viewer,state=>({...state,entries:[{intent:intent("old"),attempts:1,retryAt:0}]}));
    const queue=new V2ReadStateOutbox(store,repo,async()=>{},lock()); await queue.enqueue(intent("new","read",["other"]));
    expect((await queue.snapshot()).entries.map(value=>value.deviceCounter)).toEqual([1,2]); expect(await queue.flushOnce()).toBe(true);
    const generation=await loadV2Generation(repo); expect(generation.manifest.lastSequence).toBe(2);
    expect(generation.devices[0].committedCounter).toBe(2); expect(generation.legacyReceipts).toHaveLength(1);
    expect(generation.fragments.filter(value=>value.actionId==="old")).toHaveLength(1);
    expect(generation.fragments.find(value=>value.actionId==="old")?.deviceId).toBeUndefined();
  });
  test("two installations racing the singleton preserve both operations and receipt prefixes", async () => {
    const {repo,confirm}=await setup(); const first=new V2ReadStateOutbox(new Store(),repo,confirm,lock()),second=new V2ReadStateOutbox(new Store(),repo,confirm,lock());
    await first.enqueue(intent("first")); await second.enqueue(intent("second","read",["other"]));
    expect(await Promise.all([first.flushOnce(),second.flushOnce()])).toEqual([true,true]);
    const generation=await loadV2Generation(repo); expect(generation.devices).toHaveLength(2);expect(generation.fragments).toHaveLength(2);expect(generation.manifest.lastSequence).toBe(2);
  });
  test("repeated toggles bound canonical chain fragmentation while preserving receipt counters", async () => {
    const {repo,outbox,confirm}=await setup();const queue=outbox();
    for(let index=0;index<70;index++){await queue.enqueue(intent(`toggle-${index}`,index%2?"unread":"read"));expect(await queue.flushOnce()).toBe(true);}
    const before=await loadV2Generation(repo);expect(before.stateChunkCount).toBeLessThan(64);expect(before.devices[0].committedCounter).toBe(70);
    await compactV2Generation(repo,confirm);const after=await loadV2Generation(repo);expect(after.fragments).toHaveLength(1);
    expect(after.manifest.lastSequence).toBe(70);expect(after.manifest.revision).toBe(before.manifest.revision+1);expect(after.devices).toEqual(before.devices);
  });
  test("all roots are verified and unknown v2 fields fail closed", async () => {
    const {repo,outbox}=await setup(); const queue=outbox();await queue.enqueue(intent("first"));expect(await queue.flushOnce()).toBe(true);
    const generation=await loadV2Generation(repo), original=repo.manifest(); const state=await repo.getRecord(CHUNK_COLLECTION,generation.manifest.stateHead!.uri.split("/").at(-1)!);
    expect(()=>validateV2Chunk({...state!.value as object,unknown:true},viewer)).toThrow();
    const wrong={...generation.manifest,devicesHead:generation.manifest.stateHead}; repo.records.set(`${MANIFEST_COLLECTION}/self`,{...original,value:wrong,cid:await recordCID(wrong)});
    await expect(loadV2Generation(repo)).rejects.toThrow(); repo.records.set(`${MANIFEST_COLLECTION}/self`,original);
    repo.records.delete(`${CHUNK_COLLECTION}/${generation.manifest.devicesHead!.uri.split("/").at(-1)}`);await expect(loadV2Generation(repo)).rejects.toThrow("incomplete_generation");
  });
});

test("legacy retry payload mismatch is a protected conflict rather than a second action",async()=>{
  const repo=await activatedRepository();await commitIntent(repo,intent("old"));const store=new Store();
  await store.update(viewer,state=>({...state,entries:[{intent:intent("old","unread"),attempts:1,retryAt:0}]}));
  const queue=new V2ReadStateOutbox(store,repo,async()=>{},lock());expect(await queue.flushOnce()).toBe(false);
  expect((await queue.snapshot()).lastError).toBe("conflicting_sequence");expect((await queue.snapshot()).entries).toHaveLength(1);
  const generation=await loadV2Generation(repo);expect(generation.devices).toHaveLength(0);expect(generation.manifest.lastSequence).toBe(1);
});

test("PDS throttling persists a FIFO retry barrier across a v2 outbox restart",async()=>{
  const {PDSRequestError}=await import("../src");const {repo,store,confirm}=await setup();let now=1000;
  const create=()=>new V2ReadStateOutbox(store,repo,confirm,lock(),()=>now,()=>0);let queue=create();await queue.enqueue(intent("first"));
  repo.beforePut=async()=>{throw new PDSRequestError(429,"120");};expect(await queue.flushOnce()).toBe(false);
  await queue.enqueue(intent("second","unread"));queue=create();const attempts=(await queue.snapshot()).entries[0].attempts;
  now+=119_000;expect(await queue.flushOnce()).toBe(false);expect((await queue.snapshot()).entries[0].attempts).toBe(attempts);
  now+=1000;repo.beforePut=undefined;expect(await queue.flushOnce()).toBe(true);expect((await loadV2Generation(repo)).devices[0].committedCounter).toBe(2);
});

test("receipt-only legacy acknowledgment keeps lastSequence and retained semantics unchanged",async()=>{
  const repo=await activatedRepository();await commitIntent(repo,intent("read"));await commitIntent(repo,intent("newer","unread"));
  await ensureV2Generation(repo,async()=>{});const before=await loadV2Generation(repo),store=new Store();
  await store.update(viewer,state=>({...state,entries:[{intent:intent("read"),attempts:1,retryAt:0}]}));
  const queue=new V2ReadStateOutbox(store,repo,async()=>{},lock());expect(await queue.flushOnce()).toBe(true);
  const after=await loadV2Generation(repo);expect(after.manifest.lastSequence).toBe(2);expect(after.manifest.revision).toBe(before.manifest.revision+1);
  expect(after.fragments).toEqual(before.fragments);expect(after.devices[0].committedCounter).toBe(1);
});

test("v2 compaction preserves frozen scope breakpoints, exact exceptions, microsecond ties and calendar metadata",async()=>{
  const {repo,outbox,confirm}=await setup();const queue=outbox(),scope={publicationId:"pub",authorDid:"did:plc:author",publicationSiteKeys:["site"]};
  await queue.enqueue({actionId:"large",state:"read",actedAt:at,selection:"boundaries",boundaries:[{scope,createdAt:"2026-09-08T10:00:00.123456Z",entryId:"at://entry/z"}]});expect(await queue.flushOnce()).toBe(true);
  await queue.enqueue({actionId:"smaller",state:"unread",actedAt:at,selection:"boundaries",boundaries:[{scope,createdAt:"2026-09-08T09:00:00Z"}]});expect(await queue.flushOnce()).toBe(true);
  await queue.enqueue({...intent("calendar","read",["at://entry/a","at://entry/b"]),calendar:{cutoff:at,timeZone:"America/Chicago",referenceDate:"2026-09-08"}});expect(await queue.flushOnce()).toBe(true);
  await queue.enqueue(intent("exception","unread",["at://entry/a"]));expect(await queue.flushOnce()).toBe(true);
  const before=await loadV2Generation(repo);await compactV2Generation(repo,confirm);const after=await loadV2Generation(repo);
  for(const time of ["08:00:00","09:30:00","10:00:00.123455","10:00:00.123456","10:00:00.123457"])
    for(const uri of ["at://entry/a","at://entry/b","at://entry/y","at://entry/z","at://entry/é"])
      for(const publicationSite of ["site","other"]){const subject={uri,authorDid:scope.authorDid,publicationSite,createdAt:`2026-09-08T${time}Z`};expect(after.projection.resolve(subject)).toEqual(before.projection.resolve(subject));}
  expect(after.fragments.find(fragment=>fragment.actionId==="calendar")?.subjectUris).toEqual(["at://entry/b"]);
  expect(after.fragments.find(fragment=>fragment.actionId==="calendar")?.calendar?.timeZone).toBe("America/Chicago");
  expect(after.fragments.filter(fragment=>fragment.selection==="boundaries")).toHaveLength(2);
});

test("missing authoritative manifest never creates an empty v2 baseline or consumes pending counters",async()=>{
  const {repo,outbox}=await setup();const queue=outbox();await queue.enqueue(intent("first"));const before=await queue.snapshot(),writes=repo.writes.length;
  repo.records.delete(`${MANIFEST_COLLECTION}/self`);expect(await queue.flushOnce()).toBe(false);expect(repo.writes).toHaveLength(writes);
  expect((await queue.snapshot()).device).toEqual(before.device);expect((await queue.snapshot()).entries).toHaveLength(1);
});
