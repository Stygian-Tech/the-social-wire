import { expect, test } from "bun:test";
import { IDBFactory } from "fake-indexeddb";
import { IndexedDBReadStateOutbox, V2ReadStateOutbox, ensureV2Generation } from "../src";
import { activatedRepository, intent, lock, viewer } from "./fixture";
const name="the-social-wire.pds-read-state.v1";
async function legacyDatabase(factory:IDBFactory):Promise<IDBDatabase>{
  return new Promise((resolve,reject)=>{const request=factory.open(name,1);request.onupgradeneeded=()=>request.result.createObjectStore("viewers",{keyPath:"viewerDid"});request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error);});
}
test("schema upgrade preserves old pending payload, retry status and authority before assigning device counters",async()=>{
  const factory=new IDBFactory(),legacy=await legacyDatabase(factory);
  await new Promise<void>((resolve,reject)=>{const tx=legacy.transaction("viewers","readwrite");tx.objectStore("viewers").put({viewerDid:viewer,entries:[{intent:intent("old"),attempts:2,retryAt:3000}],verifiedAuthority:{authority:"pds",migrationState:"verified",legacyRevision:0},lastError:"reauthorize"});tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error);});legacy.close();
  const store=new IndexedDBReadStateOutbox(factory),repo=await activatedRepository(),queue=new V2ReadStateOutbox(store,repo,async()=>{},lock());
  await queue.enqueue(intent("new","read",["another"]));const state=await queue.snapshot();
  expect(state.entries.map(value=>value.deviceCounter)).toEqual([1,2]);expect(state.entries[0].intent).toEqual(intent("old"));expect(state.entries[0].attempts).toBe(2);expect(state.entries[0].retryAt).toBe(3000);expect(state.verifiedAuthority?.authority).toBe("pds");expect(state.lastError).toBe("reauthorize");
  expect((await new IndexedDBReadStateOutbox(factory).read(viewer)).device).toEqual(state.device);
});
test("concurrent tab enqueues share a single durable device identity and allocate gapless counters",async()=>{
  const factory=new IDBFactory(),repo=await activatedRepository();await ensureV2Generation(repo,async()=>{});
  const first=new V2ReadStateOutbox(new IndexedDBReadStateOutbox(factory),repo,async()=>{},lock());
  const second=new V2ReadStateOutbox(new IndexedDBReadStateOutbox(factory),repo,async()=>{},lock());
  await Promise.all(Array.from({length:20},(_,i)=>(i%2?first:second).enqueue(intent(`a-${i}`,"read",[`article-${i}`]))));
  const state=await first.snapshot();expect(state.entries.map(value=>value.deviceCounter)).toEqual(Array.from({length:20},(_,i)=>i+1));expect(state.device?.nextCounter).toBe(21);expect((await second.snapshot()).device).toEqual(state.device);
  expect((await new IndexedDBReadStateOutbox(factory).read("did:plc:other")).device).toBeUndefined();
});
test("blocked old-tab upgrade fails without clearing history and can recover once that tab closes",async()=>{
  const factory=new IDBFactory(),legacy=await legacyDatabase(factory),store=new IndexedDBReadStateOutbox(factory);
  await expect(store.read(viewer)).rejects.toThrow("Close other Social Wire tabs");legacy.close();
  const reopened=new IndexedDBReadStateOutbox(factory);expect((await reopened.read(viewer)).entries).toEqual([]);
  expect((await store.read(viewer)).entries).toEqual([]);
  await expect(legacyDatabase(factory)).rejects.toThrow();
});
test("a failed durable enqueue allocates neither an action nor a counter",async()=>{
  const factory=new IDBFactory(),store=new IndexedDBReadStateOutbox(factory),repo=await activatedRepository(),queue=new V2ReadStateOutbox(store,repo,async()=>{},lock());
  await queue.enqueue(intent("first"));const before=await queue.snapshot();
  await expect(store.update(viewer,state=>({...state,viewerDid:"did:plc:wrong",device:{...state.device!,nextCounter:900}}))).rejects.toThrow();
  expect(await queue.snapshot()).toEqual(before);
});
