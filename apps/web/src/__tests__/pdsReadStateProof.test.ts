import { expect, test } from "bun:test";
import vm from "node:vm";
import { Repo, MemoryBlockstore, getRecords, WriteOpAction, readCarWithRoot, blocksToCarFile, BlockMap } from "@atproto/repo";
import { Secp256k1Keypair, P256Keypair } from "@atproto/crypto";
import { readStateProofSession, verifyReadStateCAR } from "@/lib/pdsReadStateProof";
import { setImmediate as browserYield } from "@/lib/browserAdapters/pdsProofTimer";
const viewer="did:plc:alice",collection="app.thesocialwire.readState",rkey="self";
async function fixture(provided?:Secp256k1Keypair|P256Keypair){const key=provided??await Secp256k1Keypair.create(),store=new MemoryBlockstore();
  const repo=await Repo.create(store,viewer,key,[{action:WriteOpAction.Create,collection,rkey,record:{$type:collection,version:2,generation:"fixture",revision:1,lastSequence:0,compactionVersion:1}}]);
  const chunks=[];for await(const value of getRecords(store,repo.cid,[{collection,rkey}]))chunks.push(value);
  const car=new Uint8Array(chunks.reduce((sum,value)=>sum+value.length,0));let offset=0;for(const value of chunks){car.set(value,offset);offset+=value.length;}
  return {key,car,repo};
}
test("official signed commit and MST verification rejects tampering, missing records and wrong identity",async()=>{
  const {key,car,repo}=await fixture();const verified=await verifyReadStateCAR(car,viewer,collection,rkey,key.did());
  expect(verified.commitCid).toBe(repo.cid.toString());expect(verified.record?.value).toMatchObject({version:2,revision:1});
  const damaged=new Uint8Array(car);damaged[damaged.length-1]^=1;
  await expect(verifyReadStateCAR(damaged,viewer,collection,rkey,key.did())).rejects.toThrow();
  await expect(verifyReadStateCAR(car,"did:plc:bob",collection,rkey,key.did())).rejects.toThrow();
  await expect(verifyReadStateCAR(car,viewer,collection,rkey,(await Secp256k1Keypair.create()).did())).rejects.toThrow();
  expect((await verifyReadStateCAR(car,viewer,collection,"absent",key.did())).record).toBeNull();
  const parsed=await readCarWithRoot(car);parsed.blocks.delete((await repo.data.get(`${collection}/${rkey}`))!);
  await expect(verifyReadStateCAR(await blocksToCarFile(parsed.root,parsed.blocks),viewer,collection,rkey,key.did())).rejects.toThrow();
});
test("proof bytes and expanded block counts are bounded independently",async()=>{
  const {key,car}=await fixture();await expect(verifyReadStateCAR(new Uint8Array(512*1024+1),viewer,collection,rkey,key.did())).rejects.toThrow("size_limit");
  const parsed=await readCarWithRoot(car),blocks=new BlockMap(parsed.blocks);for(let index=0;index<1025;index++)await blocks.add({padding:index});
  await expect(verifyReadStateCAR(await blocksToCarFile(parsed.root,blocks),viewer,collection,rkey,key.did())).rejects.toThrow("size_limit");
});
test("fresh signing-key rotation aborts cleanup before its atomic write",async()=>{
  let key=(await Secp256k1Keypair.create()).did();const session=await readStateProofSession(viewer,async()=>key);
  await session.assertSigningKeyCurrent();key=(await Secp256k1Keypair.create()).did();await expect(session.assertSigningKeyCurrent()).rejects.toThrow("signing key changed");
});
test("the real browser proof bundle runs without Node globals and excludes archive stream code",async()=>{
  const build=Bun.spawn([process.execPath,`${import.meta.dir}/fixtures/pdsProofBrowserBuild.ts`],{stdout:"pipe",stderr:"pipe"});
  const [script,errors,exit]=await Promise.all([new Response(build.stdout).text(),new Response(build.stderr).text(),build.exited]);
  expect({exit,errors}).toEqual({exit:0,errors:""});expect(script).not.toContain("node:fs");expect(script).not.toContain("node:zlib");
  const context=vm.createContext({crypto,TextEncoder,TextDecoder,Uint8Array,ArrayBuffer,DataView,URL,URLSearchParams,setTimeout,clearTimeout,atob,btoa});
  expect(context.Buffer).toBeUndefined();expect(context.process).toBeUndefined();vm.runInContext(script,context);
  const {key,car}=await fixture();expect((await context.verifyReadStateCAR(car,viewer,collection,rkey,key.did())).record.value).toMatchObject({version:2});
  const damaged=new Uint8Array(car);damaged[damaged.length-1]^=1;await expect(context.verifyReadStateCAR(damaged,viewer,collection,rkey,key.did())).rejects.toThrow();
  await expect(context.verifyReadStateCAR(car,viewer,collection,rkey,(await Secp256k1Keypair.create()).did())).rejects.toThrow();
});
test("browser scheduler yields normally",async()=>{ await browserYield(); });

test("P-256 repository signing keys verify through the same official proof path",async()=>{
  const {key,car}=await fixture(await P256Keypair.create());expect((await verifyReadStateCAR(car,viewer,collection,rkey,key.did())).record?.value).toMatchObject({version:2});
});
