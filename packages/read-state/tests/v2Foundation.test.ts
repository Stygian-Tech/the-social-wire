import { describe, expect, test } from "bun:test";
import fixture from "../fixtures/v2-foundation.json";
import { ReadStateProjection } from "../src/projection";
import { advanceDeviceReceipt, compactReadState, initialDeviceReceipt, originalIntentHash, verifyDeviceAcknowledgement } from "../src/v2Foundation";
import type { Manifest, Operation, Subject } from "../src/types";
function generation(operations: Operation[], manifest = fixture.manifest as Manifest) {
  return { record: null, manifest, projection: new ReadStateProjection(operations, manifest.lastSequence), chunkCount: 1, chunkBytes: 0, repackAllowed: true };
}
describe("v2 pure foundation", () => {
  test("shared receipt vectors and deterministic fragments retain original metadata", async () => {
    const source = generation(fixture.operations as Operation[]);
    const compact = await compactReadState(source, fixture.viewerDid);
    expect(compact.operations).toEqual(fixture.compactedOperations as Operation[]);
    expect(compact.receipts).toEqual(fixture.receipts);
    expect(compact.operations.map(o=>o.sequence)).toEqual([1,2,3,6,7,8,9]);
    expect((await compactReadState(generation([...source.projection.operations].reverse()), fixture.viewerDid))).toEqual(compact);
    const initial = await initialDeviceReceipt(fixture.viewerDid, fixture.deviceId);
    expect(initial).toEqual(fixture.initialReceipt);
    const hashes = compact.receipts.map(r=>r.originalIntentHash);
    const advanced = await advanceDeviceReceipt(initial,1,hashes);
    expect(advanced).toEqual(fixture.advancedReceipt);
    expect(await verifyDeviceAcknowledgement(initial,advanced,hashes)).toBe(9);
    await expect(verifyDeviceAcknowledgement(initial,advanced,hashes.slice(1))).rejects.toThrow();
    await expect(verifyDeviceAcknowledgement(initial,advanced,hashes.map(()=>"0".repeat(64)))).rejects.toThrow();
    await expect(advanceDeviceReceipt(initial,2,hashes)).rejects.toThrow();
    await expect(initialDeviceReceipt(fixture.viewerDid,"not-a-device")).rejects.toThrow();
    const first = fixture.operations[0] as Operation;
    expect(await originalIntentHash([{...first,subjectUris:["é"]} as Operation,{...first,subjectUris:["𐀀","a"]} as Operation])).toBe(hashes[0]);
    expect(await originalIntentHash([{...first,sequence:99}])).toBe(hashes[0]);
  });
  test("unknown source semantics and ambiguous sub-microsecond boundaries fail closed", async () => {
    const operations=fixture.operations as Operation[];
    await expect(compactReadState({...generation(operations),repackAllowed:false},fixture.viewerDid)).rejects.toThrow();
    await expect(compactReadState(generation(operations,{...fixture.manifest,extra:true} as Manifest),fixture.viewerDid)).rejects.toThrow();
    await expect(originalIntentHash([{...operations[0],extra:true} as unknown as Operation])).rejects.toThrow();
    const changed=structuredClone(operations);
    changed[2].boundaries![0].createdAt="2026-11-01T06:30:00.000000001Z";
    await expect(compactReadState(generation(changed),fixture.viewerDid)).rejects.toThrow();
  });
  test("seeded exact/boundary histories preserve every resolver field for unseen future backfills", async () => {
    let seed=1234;
    const random=()=>seed=(Math.imul(seed,1664525)+1013904223)>>>0;
    const uris=["a","z","é","𐀀","late"];
    for(let trial=0;trial<24;trial++) {
      const operations:Operation[]=[];
      for(let sequence=1;sequence<=48;sequence++) {
        const common={actionId:`${trial}-${sequence}`,sequence,state:random()%2?"read" as const:"unread" as const,actedAt:sequence%2?"2026-11-01T01:30:00-05:00":"2026-11-01T01:30:00-04:00"};
        if(random()%3===0) operations.push({...common,selection:"exact",subjectUris:[uris[random()%4]]});
        else operations.push({...common,selection:"boundaries",boundaries:[{scope:{publicationId:`p${random()%2}`,authorDid:"did:plc:writer",publicationSiteKeys:random()%2?["site"]:[]},createdAt:`2026-11-01T06:30:00.${String(random()%20).padStart(6,"0")}Z`,...(random()%2?{entryId:uris[random()%4]}:{})}]});
      }
      const manifest={...fixture.manifest,lastSequence:48} as Manifest;
      const before=new ReadStateProjection(operations,48);
      const compact=await compactReadState(generation(operations,manifest),fixture.viewerDid);
      const after=new ReadStateProjection(compact.operations,48);
      for(const uri of uris) for(const micro of [0,5,10,19,20]) for(const publicationSite of ["site","unseen"]) {
        const subject:Subject={uri,authorDid:"did:plc:writer",publicationSite,createdAt:`2026-11-01T06:30:00.${String(micro).padStart(6,"0")}Z`};
        expect(after.resolve(subject)).toEqual(before.resolve(subject));
      }
      expect((await compactReadState(generation([...operations].reverse(),manifest),fixture.viewerDid))).toEqual(compact);
    }
  });
});
