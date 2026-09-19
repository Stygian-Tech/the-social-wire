import type { OAuthSession } from "@atproto/oauth-client-browser";
import { CHUNK_COLLECTION, MANIFEST_COLLECTION, PDSRequestError, ReadStateError, recordCID,
  type OutboxStore, type ReadStateGarbageCollectionStore, type ReadStateGarbageCollectionState,
  type ReadStateGarbageCollectionTransport, type Reference, type RepositoryRecord,
  type V2Manifest, type VerifiedReadStateRecord } from "@thesocialwire/read-state";
import { OAuthReadStateRepository } from "./pdsReadStateRepository";

export const pdsReadStateGarbageCollectionEnabled = () => process.env.NEXT_PUBLIC_PDS_READ_STATE_GC_ENABLED === "true";
/** Only supply a reviewed verifier that checks block CIDs, the current viewer DID signing key,
 * signed repo commit, and exact MST membership/absence. Unknown keys/rotation fail closed. */
export type ReadStateCARVerifier = (car: Uint8Array, viewer: string, collection: string, rkey: string) => Promise<VerifiedReadStateRecord>;
async function boundedBody(response: Response, maximum: number): Promise<Uint8Array> {
  if(Number(response.headers.get("content-length"))>maximum){await response.body?.cancel();throw new ReadStateError("size_limit");}
  const reader=response.body?.getReader();if(!reader)throw new ReadStateError("incomplete_generation");
  const parts:Uint8Array[]=[];let size=0;
  try { for(;;){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;
    if(size>maximum)throw new ReadStateError("size_limit");parts.push(value);} }
  finally { await reader.cancel().catch(()=>{});reader.releaseLock(); }
  const result=new Uint8Array(size);let offset=0;for(const part of parts){result.set(part,offset);offset+=part.byteLength;}return result;
}
/** No proof implementation is selected by default. GC cannot run on JSON reads alone. */
export class OAuthReadStateGarbageCollection extends OAuthReadStateRepository implements ReadStateGarbageCollectionTransport {
  constructor(private readonly oauth: OAuthSession, private readonly ensureCurrent:()=>void,
    private readonly verifier?:ReadStateCARVerifier, private readonly verifySigningKeyCurrent?:()=>Promise<void>){super(oauth,ensureCurrent);}
  private async request(path:string,maximum:number,body?:unknown):Promise<Uint8Array>{
    this.ensureCurrent();
    const response=await this.oauth.fetchHandler(`/xrpc/${path}`,{signal:AbortSignal.timeout(20_000),
      ...(body?{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify(body)}:{})});
    const bytes=await boundedBody(response,maximum);this.ensureCurrent();
    if(!response.ok){let error:string|undefined;try{error=JSON.parse(new TextDecoder().decode(bytes)).error;}catch{}
      if(error==="InvalidSwap")throw new ReadStateError("conflict");
      if(response.status===401||response.status===403)throw new ReadStateError("reauthorize");
      throw new PDSRequestError(response.status,response.headers.get("retry-after")??undefined,response.headers.get("ratelimit-reset")??undefined,error);
    }
    return bytes;
  }
  async verifiedRecord(collection:string,rkey:string):Promise<VerifiedReadStateRecord>{
    if(!this.verifier)throw new ReadStateError("unavailable","Verified repository proof support is required before cleanup can run.");
    if(collection!==CHUNK_COLLECTION&&!(collection===MANIFEST_COLLECTION&&rkey==="self"))throw new ReadStateError("invalid_reference");
    const query=new URLSearchParams({did:this.viewerDid,collection,rkey});
    const bytes=await this.request(`com.atproto.sync.getRecord?${query}`,512*1024);
    const result=await this.verifier(bytes,this.viewerDid,collection,rkey);this.ensureCurrent();
    if(!result.commitCid||result.record&&(result.record.uri!==`at://${this.viewerDid}/${collection}/${rkey}`
      ||result.record.cid!==await recordCID(result.record.value)))throw new ReadStateError("invalid_reference");
    return result;
  }
  async listChunks(cursor?:string):Promise<{records:RepositoryRecord[];cursor?:string}>{
    const query=new URLSearchParams({repo:this.viewerDid,collection:CHUNK_COLLECTION,limit:"100",...(cursor?{cursor}:{})});
    const result=JSON.parse(new TextDecoder().decode(await this.request(`com.atproto.repo.listRecords?${query}`,8*1024*1024))) as {records:RepositoryRecord[];cursor?:string};
    if(!Array.isArray(result.records)||result.records.length>100||result.cursor!==undefined&&typeof result.cursor!=="string")throw new ReadStateError("invalid_record");
    return result;
  }
  async atomicCollect(baseCommit:string,manifest:V2Manifest,candidates:Reference[]):Promise<{commitCid:string}>{
    // A missing delete grant never prevents ordinary read-state writes or reading the app.
    if(!this.verifier||!this.verifySigningKeyCurrent)throw new ReadStateError("unavailable");
    await this.verifySigningKeyCurrent();this.ensureCurrent();
    const grants=(await this.oauth.getTokenInfo(false)).scope.split(" ");
    const allowed=grants.some(grant=>{const [name,query]=grant.split("?");return name===`repo:${CHUNK_COLLECTION}`&&new URLSearchParams(query).getAll("action").includes("delete");});
    if(!allowed)throw new ReadStateError("reauthorize");
    if(!baseCommit||!candidates.length||candidates.length>100||new Set(candidates.map(value=>value.uri)).size!==candidates.length
      ||candidates.some(value=>!value.uri.startsWith(`at://${this.viewerDid}/${CHUNK_COLLECTION}/`)||value.uri.split("/").length!==5))throw new ReadStateError("invalid_reference");
    const body={repo:this.viewerDid,swapCommit:baseCommit,writes:[
      {$type:"com.atproto.repo.applyWrites#update",collection:MANIFEST_COLLECTION,rkey:"self",value:manifest},
      ...candidates.map(value=>({$type:"com.atproto.repo.applyWrites#delete",collection:CHUNK_COLLECTION,rkey:value.uri.split("/").at(-1)!}))]};
    const result=JSON.parse(new TextDecoder().decode(await this.request("com.atproto.repo.applyWrites",512*1024,body))) as {commit?:{cid?:string}};
    if(!result.commit?.cid)throw new ReadStateError("incomplete_generation");
    return {commitCid:result.commit.cid};
  }
}
/** Shares the viewer's durable database but updates only GC fields. */
export class IndexedDBReadStateGarbageCollectionStore implements ReadStateGarbageCollectionStore {
  constructor(private readonly outbox:OutboxStore){}
  async read(viewer:string):Promise<ReadStateGarbageCollectionState>{return (await this.outbox.read(viewer)).garbageCollection??{viewerDid:viewer,candidates:[]};}
  async write(garbageCollection:ReadStateGarbageCollectionState):Promise<void>{
    await this.outbox.update(garbageCollection.viewerDid,state=>({...state,garbageCollection}));
  }
}
