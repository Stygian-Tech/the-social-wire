import {expect,test} from "bun:test";
import { CHUNK_COLLECTION, MANIFEST_COLLECTION, ReadStateError, collectReadStateGarbage, ensureV2Generation,
  loadV2Generation, recordCID, type ReadStateGarbageCollectionState, type ReadStateGarbageCollectionStore,
  type ReadStateGarbageCollectionTransport, type Reference, type V2Manifest } from "../src";
import { Repository, viewer, activatedRepository, intent } from "./fixture";

// Transaction model checks the engine's fencing obligations. Hosted PDS conformance is a separate activation gate.
class TransactionRepository extends Repository implements ReadStateGarbageCollectionTransport{
  commit="commit-1";batches=0;lostResponse=false;beforeAtomic?:()=>Promise<void>;wrongCandidateCommit=false;
  async verifiedRecord(collection:string,rkey:string){return {commitCid:this.wrongCandidateCommit&&collection===CHUNK_COLLECTION?"different-commit":this.commit,record:await this.getRecord(collection,rkey)};}
  async listChunks(){return {records:this.chunks().slice(0,100)};}
  async atomicCollect(baseCommit:string,manifest:V2Manifest,candidates:Reference[]){
    await this.beforeAtomic?.();const cid=await recordCID(manifest);
    if(baseCommit!==this.commit)throw new ReadStateError("conflict");
    this.records.set(`${MANIFEST_COLLECTION}/self`,{uri:`at://${viewer}/${MANIFEST_COLLECTION}/self`,cid,value:manifest});
    for(const candidate of candidates)this.records.delete(`${CHUNK_COLLECTION}/${candidate.uri.split("/").at(-1)}`);
    this.commit=`commit-${++this.batches+1}`;if(this.lostResponse){this.lostResponse=false;throw new Error("Lost response");}return {commitCid:this.commit};
  }
}
class GCStore implements ReadStateGarbageCollectionStore{
  state:ReadStateGarbageCollectionState={viewerDid:viewer,candidates:[]};fail=false;
  async read(){return structuredClone(this.state);}
  async write(value:ReadStateGarbageCollectionState){if(this.fail)throw new Error("Disk unavailable");this.state=structuredClone(value);}
}
async function setup(){const initial=await activatedRepository(),repo=new TransactionRepository();repo.records=initial.records;await ensureV2Generation(repo,async()=>{});
  const value={$type:CHUNK_COLLECTION as typeof CHUNK_COLLECTION,version:1 as const,operations:[{...intent("orphan"),sequence:1}]};
  const orphan=await repo.putRecord(CHUNK_COLLECTION,"orphan",value,null),store=new GCStore();let now=0;
  let monotonic:number|undefined;
  const run=(enabled=true,protectedUploads:Reference[]=[])=>collectReadStateGarbage(repo,store,async()=>{},{enabled,now,protectedUploads,clock:{epoch:"test-clock",monotonic:monotonic??now}});
  const age=async()=>{for(let i=0;i<5;i++){now=i*6*3600_000;await run();}};
  return {repo,store,orphan,run,age,setTime:(value:number)=>{now=value;},setMonotonic:(value:number)=>{monotonic=value;}};
}
test("cleanup is disabled without even reading the repository or changing the ledger",async()=>{
  const {repo,store,run}=await setup();repo.verifiedRecord=async()=>{throw new Error("Must not fetch");};expect(await run(false)).toEqual({observed:0,deleted:0});expect(store.state.candidates).toEqual([]);
});
test("24 hours of observed grace precedes one atomic revision bump and orphan deletion",async()=>{
  const {repo,store,run,setTime,orphan}=await setup();const before=await loadV2Generation(repo);expect(await run()).toEqual({observed:1,deleted:0});
  for(let hour=6;hour<24;hour+=6){setTime(hour*3600_000);expect((await run()).deleted).toBe(0);}setTime(24*3600_000);expect((await run()).deleted).toBe(1);
  expect(await repo.getRecord(CHUNK_COLLECTION,"orphan")).toBeNull();expect(store.state.candidates).toEqual([]);
  const after=await loadV2Generation(repo);expect(after.manifest.revision).toBe(before.manifest.revision+1);expect(after.manifest.lastSequence).toBe(before.manifest.lastSequence);
  await expect(repo.putRecord(MANIFEST_COLLECTION,"self",{...before.manifest,generation:"paused-writer",stateHead:orphan},before.record.cid)).rejects.toThrow("conflict");
});
test("writer-first commit change rejects the entire deletion batch",async()=>{
  const {repo,run,setTime}=await setup();for(let hour=0;hour<24;hour+=6){setTime(hour*3600_000);await run();}
  repo.beforeAtomic=async()=>{repo.commit="writer-commit";};setTime(24*3600_000);await expect(run()).rejects.toThrow("conflict");expect(repo.batches).toBe(0);expect(await repo.getRecord(CHUNK_COLLECTION,"orphan")).not.toBeNull();
});
test("unproven replacement CID at an old candidate rkey never inherits its deletion age",async()=>{
  const {repo,run,setTime}=await setup();for(let hour=0;hour<24;hour+=6){setTime(hour*3600_000);await run();}
  const old=(await repo.getRecord(CHUNK_COLLECTION,"orphan"))!;const value={...old.value as object,operations:[{...intent("replacement"),sequence:1}]};
  await repo.putRecord(CHUNK_COLLECTION,"orphan",value as never,old.cid);setTime(24*3600_000);expect((await run()).deleted).toBe(0);expect(repo.batches).toBe(0);
});
test("candidate proof from another repo commit aborts before any deletion",async()=>{
  const {repo,run,setTime}=await setup();for(let hour=0;hour<24;hour+=6){setTime(hour*3600_000);await run();}
  repo.wrongCandidateCommit=true;setTime(24*3600_000);await expect(run()).rejects.toThrow("conflict");expect(repo.batches).toBe(0);
});
test("unknown response restarts from current proof and never blindly resends the old batch",async()=>{
  const {repo,store,run,setTime}=await setup();for(let hour=0;hour<24;hour+=6){setTime(hour*3600_000);await run();}
  repo.lostResponse=true;setTime(24*3600_000);await expect(run()).rejects.toThrow("Lost response");expect(store.state.pending).toBeDefined();
  expect((await run()).deleted).toBe(0);expect(repo.batches).toBe(1);expect(store.state.pending).toBeUndefined();
});
test("clock uncertainty resets grace and locally pending uploads are protected",async()=>{
  const {repo,run,setTime,setMonotonic,orphan}=await setup();await run();setTime(24*3600_000);setMonotonic(3600_000);expect((await run()).deleted).toBe(0);
  for(let hour=30;hour<=48;hour+=6){setTime(hour*3600_000);expect((await run(true,[orphan])).deleted).toBe(0);}expect(repo.batches).toBe(0);
});
test("failed ledger persistence prevents external mutation",async()=>{
  const {repo,store,run}=await setup();store.fail=true;await expect(run()).rejects.toThrow("Disk unavailable");expect(repo.batches).toBe(0);
});

test("all three current roots and unknown extension records survive collection",async()=>{
  const {V2ReadStateOutbox,commitIntent}=await import("../src"),{Store,lock}=await import("./fixture");
  const initial=await activatedRepository();await commitIntent(initial,intent("legacy"));const repo=new TransactionRepository();repo.records=initial.records;
  await ensureV2Generation(repo,async()=>{});const queue=new V2ReadStateOutbox(new Store(),repo,async()=>{},lock());await queue.enqueue(intent("new","read",["other"]));expect(await queue.flushOnce()).toBe(true);
  const before=await loadV2Generation(repo);expect(before.manifest.stateHead).toBeDefined();expect(before.manifest.devicesHead).toBeDefined();expect(before.manifest.legacyReceiptsHead).toBeDefined();
  await repo.putRecord(CHUNK_COLLECTION,"unknown",{$type:CHUNK_COLLECTION,version:1,operations:[{...intent("unknown"),sequence:1}],unknownMeaning:true} as never,null);
  const store=new GCStore();for(let hour=0;hour<=24;hour+=6)await collectReadStateGarbage(repo,store,async()=>{},{enabled:true,now:hour*3600_000,clock:{epoch:"same",monotonic:hour*3600_000}});
  const after=await loadV2Generation(repo);expect(after.fragments).toEqual(before.fragments);expect(after.devices).toEqual(before.devices);expect(after.legacyReceipts).toEqual(before.legacyReceipts);
  expect(await repo.getRecord(CHUNK_COLLECTION,"unknown")).not.toBeNull();
});
test("one collection transaction never exceeds 100 deletes",async()=>{
  const {repo,store,run,setTime}=await setup();const records=[];
  for(let index=0;index<101;index++)records.push(await repo.putRecord(CHUNK_COLLECTION,`candidate-${index}`,{$type:CHUNK_COLLECTION,version:1,operations:[{...intent(`action-${index}`),sequence:1}]},null));
  store.state={viewerDid:viewer,candidates:records.map(record=>({...record,firstSeenAt:0,firstSeenMonotonic:0})),clockEpoch:"test-clock",observedAt:18*3600_000,monotonicObservedAt:18*3600_000};
  setTime(24*3600_000);expect((await run()).deleted).toBe(100);expect(repo.batches).toBe(1);expect(await repo.getRecord(CHUNK_COLLECTION,"candidate-100")).not.toBeNull();
});
