import { CHUNK_COLLECTION, MANIFEST_COLLECTION, ReadStateError, type Reference } from "./types";
import { recordCID, type ReadStateRepository, type RepositoryRecord } from "./repository";
import { loadV2Generation } from "./v2Repository";
import { validateV2Chunk, validateV2Manifest } from "./v2Validation";
import { PDSRequestError } from "./outbox";
import { validateChunk, validateReference } from "./validation";
import type { V2Manifest } from "./v2Types";

export type VerifiedReadStateRecord = { commitCid: string; record: RepositoryRecord | null };
/** Adapter must verify CAR block CIDs, viewer signature, and exact MST membership/absence.
 * A JSON getRecord, ordinary 404, or unrelated getLatestCommit never satisfies this contract. */
export interface ReadStateGarbageCollectionTransport extends ReadStateRepository {
  verifiedRecord(collection: string, rkey: string): Promise<VerifiedReadStateRecord>;
  listChunks(cursor?: string): Promise<{ records: RepositoryRecord[]; cursor?: string }>;
  atomicCollect(baseCommit: string, manifest: V2Manifest, candidates: Reference[]): Promise<{ commitCid: string }>;
}
export type GarbageCollectionCandidate = Reference & { firstSeenAt: number; firstSeenMonotonic?: number };
export type ReadStateGarbageCollectionState = { viewerDid: string; candidates: GarbageCollectionCandidate[];
  cursor?: string; lastError?: string; observedAt?: number; clockEpoch?: string; monotonicObservedAt?: number; pending?: { baseCommit: string; manifestCid: string; candidates: Reference[] } };
export interface ReadStateGarbageCollectionStore {
  read(viewer: string): Promise<ReadStateGarbageCollectionState>;
  write(state: ReadStateGarbageCollectionState): Promise<void>;
}
const GRACE = 24 * 60 * 60 * 1000;
const MAX_CANDIDATES = 2000;
const rkey = (uri: string) => uri.split("/").at(-1)!;
async function knownChunk(record: RepositoryRecord, viewer: string): Promise<boolean> {
  if (!record.uri.startsWith(`at://${viewer}/${CHUNK_COLLECTION}/`) || rkey(record.uri).includes("?")
    || record.uri !== `at://${viewer}/${CHUNK_COLLECTION}/${rkey(record.uri)}` || record.cid !== await recordCID(record.value)) return false;
  try {
    validateReference(record, viewer);
    if ((record.value as {version?:number}).version === 2) validateV2Chunk(record.value, viewer);
    else {
      validateChunk(record.value, viewer);
      const chunk=record.value;
      if(chunk.previous&&Object.keys(chunk.previous).some(key=>!["uri","cid"].includes(key)))return false;
      if(Object.keys(chunk).some(key=>!["$type","version","operations","previous"].includes(key)))return false;
      for(const operation of chunk.operations){
        if(Object.keys(operation).some(key=>!["actionId","sequence","state","actedAt","selection","boundaries","subjectUris","calendar"].includes(key)))return false;
        if(operation.calendar&&Object.keys(operation.calendar).some(key=>!["cutoff","timeZone","referenceDate"].includes(key)))return false;
        for(const boundary of operation.boundaries??[])if(Object.keys(boundary).some(key=>!["scope","createdAt","entryId"].includes(key))
          ||Object.keys(boundary.scope).some(key=>!["publicationId","authorDid","publicationSiteKeys"].includes(key)))return false;
      }
    }
    return true;
  } catch { return false; }
}
/** One bounded page and at most 100 deletes. Caller serializes this with the viewer outbox.
 * No loop runs automatically and there is deliberately no individual-delete fallback. */
export async function collectReadStateGarbage(transport: ReadStateGarbageCollectionTransport,
  store: ReadStateGarbageCollectionStore, confirm: (record: Reference) => Promise<void>,
  options: { enabled: boolean; now: number; protectedUploads?: Reference[]; clock?: { epoch: string; monotonic: number } }): Promise<{ observed: number; deleted: number }> {
  if(!options.enabled)return {observed:0,deleted:0};
  const started=performance.now();
  const checkBudget=()=>{if(performance.now()-started>30_000)throw new ReadStateError("size_limit");};
  const now=options.now;if(!Number.isSafeInteger(now)||now<0)throw new ReadStateError("invalid_record");
  const clock=options.clock??{epoch:String(performance.timeOrigin),monotonic:performance.now()};
  if(!clock.epoch||!Number.isFinite(clock.monotonic)||clock.monotonic<0)throw new ReadStateError("invalid_record");
  let ledger=await store.read(transport.viewerDid);
  if(ledger.viewerDid!==transport.viewerDid||ledger.candidates.length>MAX_CANDIDATES)throw new ReadStateError("invalid_record");
  const proof=await transport.verifiedRecord(MANIFEST_COLLECTION,"self");
  if(!proof.commitCid||!proof.record)throw new ReadStateError("incomplete_generation");
  validateV2Manifest(proof.record.value,transport.viewerDid);
  const generation=await loadV2Generation(transport,proof.record);await confirm(generation.record);checkBudget();
  const reachable=new Set(generation.references.map(ref=>ref.uri));
  for(const ref of options.protectedUploads??[])reachable.add(ref.uri);
  // A new browser clock epoch, backward movement, or divergent wall/monotonic clocks
  // resets grace. Neither a changed device clock nor a stale wall timestamp authorizes deletion.
  const clockUncertain=ledger.clockEpoch!==clock.epoch||ledger.monotonicObservedAt===undefined||ledger.observedAt===undefined
    ||now<ledger.observedAt||clock.monotonic<ledger.monotonicObservedAt
    ||Math.abs((now-ledger.observedAt)-(clock.monotonic-ledger.monotonicObservedAt))>60_000;
  const candidates=new Map(ledger.candidates.filter(candidate=>!reachable.has(candidate.uri)).map(candidate=>[candidate.uri,
    {...candidate,firstSeenAt:clockUncertain?now:candidate.firstSeenAt,
      firstSeenMonotonic:clockUncertain?clock.monotonic:candidate.firstSeenMonotonic}]));
  const page=await transport.listChunks(ledger.cursor);
  if(page.records.length>100||page.cursor===ledger.cursor&&page.cursor!==undefined)throw new ReadStateError("size_limit");
  let observed=0;
  for(const record of page.records){
    if(reachable.has(record.uri)||!await knownChunk(record,transport.viewerDid))continue;
    const old=candidates.get(record.uri);
    if(old?.cid===record.cid)continue;
    if(!old&&candidates.size===MAX_CANDIDATES)continue;
    candidates.set(record.uri,{uri:record.uri,cid:record.cid,firstSeenAt:now,firstSeenMonotonic:clock.monotonic});observed++;
  }
  ledger={viewerDid:transport.viewerDid,candidates:[...candidates.values()],observedAt:now,clockEpoch:clock.epoch,monotonicObservedAt:clock.monotonic,...(page.cursor?{cursor:page.cursor}:{})};
  await store.write(ledger);
  const deletions:Reference[]=[];
  for(const candidate of ledger.candidates){
    if(deletions.length===100)break;
    if(!Number.isSafeInteger(candidate.firstSeenAt)||candidate.firstSeenAt>now||now-candidate.firstSeenAt<GRACE
      ||candidate.firstSeenMonotonic===undefined||clock.monotonic-candidate.firstSeenMonotonic<GRACE)continue;
    checkBudget();
    let current:VerifiedReadStateRecord;
    try { current=await transport.verifiedRecord(CHUNK_COLLECTION,rkey(candidate.uri)); }
    catch(error){
      // Ordinary missing responses are not absence proofs. Never delete or acknowledge them.
      if(error instanceof PDSRequestError && (error.status===404 || error.status===400&&error.code==="RecordNotFound"))continue;
      throw error;
    }
    checkBudget();
    if(current.commitCid!==proof.commitCid)throw new ReadStateError("conflict");
    if(!current.record||current.record.uri!==candidate.uri||current.record.cid!==candidate.cid||!await knownChunk(current.record,transport.viewerDid))continue;
    deletions.push({uri:candidate.uri,cid:candidate.cid});
  }
  if(!deletions.length)return {observed,deleted:0};
  const manifest:V2Manifest={...generation.manifest,generation:crypto.randomUUID(),revision:generation.manifest.revision+1};
  validateV2Manifest(manifest,transport.viewerDid);const manifestCid=await recordCID(manifest);
  // Persist before the external transaction. Lost responses always reload proof/reachability;
  // never blindly replay a previous deletion plan.
  await store.write({...ledger,pending:{baseCommit:proof.commitCid,manifestCid,candidates:deletions}});
  checkBudget();
  const result=await transport.atomicCollect(proof.commitCid,manifest,deletions);
  const verified=await transport.verifiedRecord(MANIFEST_COLLECTION,"self");
  if(verified.commitCid!==result.commitCid||verified.record?.cid!==manifestCid)throw new ReadStateError("conflict");
  await loadV2Generation(transport,verified.record);await confirm(verified.record);
  const deleted=new Set(deletions.map(value=>`${value.uri}:${value.cid}`));
  await store.write({...ledger,candidates:ledger.candidates.filter(value=>!deleted.has(`${value.uri}:${value.cid}`))});
  return {observed,deleted:deletions.length};
}
