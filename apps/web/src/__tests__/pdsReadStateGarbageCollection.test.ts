import {expect,test} from "bun:test";
import type {OAuthSession} from "@atproto/oauth-client-browser";
import {CHUNK_COLLECTION,MANIFEST_COLLECTION,recordCID,type V2Manifest} from "@thesocialwire/read-state";
import {OAuthReadStateGarbageCollection,pdsReadStateGarbageCollectionEnabled} from "@/lib/pdsReadStateGarbageCollection";
import {OAuthReadStateRepository} from "@/lib/pdsReadStateRepository";
import {PDS_READ_STATE_REPO_SCOPES} from "@/lib/atprotoOAuthScopes";
const did="did:plc:alice",manifest:V2Manifest={$type:MANIFEST_COLLECTION,version:2,generation:"gc",revision:2,lastSequence:0,compactionVersion:1};
const candidate={uri:`at://${did}/${CHUNK_COLLECTION}/old`,cid:"prior-chunk-cid"};
const verifier=async()=>({commitCid:"current-commit",record:null});
function session(fetchHandler:OAuthSession["fetchHandler"],scope=`repo:${CHUNK_COLLECTION}?action=create&action=update&action=delete`):OAuthSession{
  return {did,fetchHandler,getTokenInfo:async()=>({scope})} as unknown as OAuthSession;
}
test("cleanup is default OFF and unavailable proof support sends no requests",async()=>{
  const previous=process.env.NEXT_PUBLIC_PDS_READ_STATE_GC_ENABLED;delete process.env.NEXT_PUBLIC_PDS_READ_STATE_GC_ENABLED;
  try{expect(pdsReadStateGarbageCollectionEnabled()).toBe(false);}finally{if(previous!==undefined)process.env.NEXT_PUBLIC_PDS_READ_STATE_GC_ENABLED=previous;}
  let requests=0;const repo=new OAuthReadStateGarbageCollection(session(async()=>{requests++;return Response.json({});}),()=>{});
  await expect(repo.verifiedRecord(MANIFEST_COLLECTION,"self")).rejects.toThrow("proof support");expect(requests).toBe(0);
});
test("authenticated cleanup is exactly one whole-repository CAS transaction with singleton update and scoped deletes",async()=>{
  const requests:{path:string;body:Record<string,unknown>}[]=[];let checkedKey=0;
  const repo=new OAuthReadStateGarbageCollection(session(async(path,init)=>{requests.push({path,body:JSON.parse(String(init?.body))});return Response.json({commit:{cid:"next-commit"}});}),()=>{},verifier,async()=>{checkedKey++;});
  expect(await repo.atomicCollect("anchored-commit",manifest,[candidate])).toEqual({commitCid:"next-commit"});expect(checkedKey).toBe(1);
  expect(requests).toHaveLength(1);expect(requests[0].path).toBe("/xrpc/com.atproto.repo.applyWrites");
  expect(requests[0].body).toEqual({repo:did,swapCommit:"anchored-commit",writes:[{$type:"com.atproto.repo.applyWrites#update",collection:MANIFEST_COLLECTION,rkey:"self",value:manifest},{$type:"com.atproto.repo.applyWrites#delete",collection:CHUNK_COLLECTION,rkey:"old"}]});
});
test("delete scope is optional for ordinary writes but required before cleanup",async()=>{
  let requests=0;const oauth=session(async(_path,init)=>{requests++;const body=JSON.parse(await new Response(init?.body).text());return Response.json({uri:`at://${did}/${body.collection}/${body.rkey}`,cid:await recordCID(body.record)});},`repo:${CHUNK_COLLECTION}?action=create&action=update`);
  await new OAuthReadStateRepository(oauth,()=>{}).putRecord(MANIFEST_COLLECTION,"self",manifest,"base");expect(requests).toBe(1);
  const gc=new OAuthReadStateGarbageCollection(oauth,()=>{},verifier,async()=>{});await expect(gc.atomicCollect("base",manifest,[candidate])).rejects.toThrow("reauthorize");expect(requests).toBe(1);
  expect(PDS_READ_STATE_REPO_SCOPES).toContain(`repo:${CHUNK_COLLECTION}?action=create&action=update&action=delete`);
});
test("proof fetch is bounded after decompression and ordinary missing responses are never proof of absence",async()=>{
  let verified=0;const large=new OAuthReadStateGarbageCollection(session(async()=>new Response(new Uint8Array(512*1024+1))),()=>{},async()=>{verified++;return verifier();});
  await expect(large.verifiedRecord(MANIFEST_COLLECTION,"self")).rejects.toThrow("size_limit");expect(verified).toBe(0);
  const missing=new OAuthReadStateGarbageCollection(session(async()=>Response.json({error:"RecordNotFound"},{status:400})),()=>{},verifier);
  await expect(missing.verifiedRecord(CHUNK_COLLECTION,"old")).rejects.toMatchObject({status:400,code:"RecordNotFound"});
});
test("key rotation and invalid viewer candidate stop before atomic writes",async()=>{
  let requests=0;const oauth=session(async()=>{requests++;return Response.json({});});
  const rotated=new OAuthReadStateGarbageCollection(oauth,()=>{},verifier,async()=>{throw new Error("Key changed");});
  await expect(rotated.atomicCollect("base",manifest,[candidate])).rejects.toThrow("Key changed");
  const repo=new OAuthReadStateGarbageCollection(oauth,()=>{},verifier,async()=>{});
  await expect(repo.atomicCollect("base",manifest,[{...candidate,uri:`at://did:plc:bob/${CHUNK_COLLECTION}/old`}])).rejects.toThrow("invalid_reference");expect(requests).toBe(0);
});
test("GC transport retains throttling and refuses to trust a verifier result for another record",async()=>{
  const throttled=new OAuthReadStateGarbageCollection(session(async()=>Response.json({error:"RateLimitExceeded"},{status:429,headers:{"retry-after":"120"}})),()=>{},verifier);
  await expect(throttled.listChunks()).rejects.toMatchObject({status:429,retryAfter:"120"});
  const wrong=new OAuthReadStateGarbageCollection(session(async()=>new Response(new Uint8Array([1]))),()=>{},async()=>({commitCid:"commit",record:{uri:`at://did:plc:bob/${MANIFEST_COLLECTION}/self`,cid:await recordCID(manifest),value:manifest}}));
  await expect(wrong.verifiedRecord(MANIFEST_COLLECTION,"self")).rejects.toThrow("invalid_reference");
});
