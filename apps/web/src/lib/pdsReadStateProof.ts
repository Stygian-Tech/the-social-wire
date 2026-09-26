import { Buffer as BrowserBuffer } from "buffer/";
import { MemoryBlockstore, MST, def, readCarWithRoot, verifyProofs } from "@atproto/repo";
import { ReadStateError, type VerifiedReadStateRecord } from "@thesocialwire/read-state";
import type { ReadStateCARVerifier } from "./pdsReadStateGarbageCollection";

// The official CAR reader uses Buffer.concat for varints. Install the standard browser
// implementation only when this lazy GC bundle loads, never replace an existing implementation.
const browserGlobal = globalThis as unknown as { Buffer?: typeof BrowserBuffer };
if (!browserGlobal.Buffer) browserGlobal.Buffer = BrowserBuffer;

export async function verifyReadStateCAR(carBytes: Uint8Array, viewer: string, collection: string, rkey: string,
  signingKey: string): Promise<VerifiedReadStateRecord> {
  if(carBytes.byteLength>512*1024||!signingKey.startsWith("did:key:z"))throw new ReadStateError("size_limit");
  const car=await readCarWithRoot(carBytes); // Official reader verifies every block CID by default.
  if(car.blocks.size>1024||car.blocks.byteSize>512*1024)throw new ReadStateError("size_limit");
  const store=new MemoryBlockstore(car.blocks),commit=await store.readObj(car.root,def.commit);
  if(commit.version!==3||commit.did!==viewer)throw new ReadStateError("invalid_reference");
  const cid=await MST.load(store,commit.data).get(`${collection}/${rkey}`);
  const proof=await verifyProofs(carBytes,[{collection,rkey,cid:cid??null}],viewer,signingKey);
  if(proof.verified.length!==1||proof.unverified.length)throw new ReadStateError("invalid_reference");
  return {commitCid:car.root.toString(),record:cid?{uri:`at://${viewer}/${collection}/${rkey}`,cid:cid.toString(),value:await store.readObj(cid,def.map)}:null};
}
/** A fresh DID lookup at the start and immediately before deletion fences key rotation.
 * Intermediate proofs in the same bounded run reuse this key instead of refetching it per candidate. */
export async function readStateProofSession(viewer: string, resolveSigningKey:()=>Promise<string>):Promise<{
  verify:ReadStateCARVerifier;assertSigningKeyCurrent:()=>Promise<void>;
}>{
  const signingKey=await resolveSigningKey();
  return {verify:async(bytes,did,collection,rkey)=>{
    if(did!==viewer)throw new ReadStateError("invalid_reference");return verifyReadStateCAR(bytes,did,collection,rkey,signingKey);
  },assertSigningKeyCurrent:async()=>{if(await resolveSigningKey()!==signingKey)throw new ReadStateError("unavailable","The repository signing key changed; retry cleanup with a fresh proof.");}};
}
