import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { SQL, S3Client } from "bun";
import { randomUUID } from "node:crypto";
import { PodcastWorker } from "../src/worker";
import { upsertPodcastEpisode } from "../src/catalog";

const url=process.env.PODCAST_TEST_DATABASE_URL;
const schema=`podcast_test_${randomUUID().replaceAll("-","")}`;
let database:SQL;let second:SQL;
describe.skipIf(!url)("durable podcast jobs on disposable PostgreSQL",()=>{
  beforeAll(async()=>{
    const parsed=new URL(url!);
    if(!["localhost","127.0.0.1"].includes(parsed.hostname))throw new Error("Podcast database tests require disposable loopback PostgreSQL");
    database=new SQL({url:url!,max:1,idleTimeout:0});second=new SQL({url:url!,max:1,idleTimeout:0});
    await database.unsafe(`CREATE SCHEMA ${schema}`);
    await database.unsafe(`SET search_path TO ${schema}`);await second.unsafe(`SET search_path TO ${schema}`);
    const migration=await Bun.file(new URL("../../../database/migrations/20261005010000_podcast_listener.sql",import.meta.url)).text();
    await database.unsafe(migration);
  });
  afterAll(async()=>{
    if(second)await second.close();
    if(database){await database.unsafe(`DROP SCHEMA ${schema} CASCADE`);await database.close();}
  });
  it("claims work atomically across workers and reacquires expired leases",async()=>{
    const id=randomUUID();
    await database`INSERT INTO podcast_jobs(id,kind,dedupe_key,payload_json) VALUES(${id}::uuid,'transcript',${id},'{}'::jsonb)`;
    const one=new PodcastWorker(database,new S3Client());const two=new PodcastWorker(second,new S3Client());
    const claims=await Promise.all([one.claim(),two.claim()]);
    expect(claims.filter(Boolean)).toHaveLength(1);expect(claims.find(Boolean)?.attempts).toBe(1);
    await database`UPDATE podcast_jobs SET lease_until=now()-interval '1 second' WHERE id=${id}::uuid`;
    expect((await two.claim())?.attempts).toBe(2);
    await database`UPDATE podcast_jobs SET status='complete' WHERE id=${id}::uuid`;
    expect(await one.claim()).toBeUndefined();
  });
  it("does not lease or publish queued bridge jobs when the bridge flag is off",async()=>{
    const previous=process.env.PODCAST_BRIDGE_ENABLED;delete process.env.PODCAST_BRIDGE_ENABLED;
    const id=randomUUID();
    try {
      await database`INSERT INTO podcast_jobs(id,kind,dedupe_key,payload_json) VALUES(${id}::uuid,'bridge',${id},'{}'::jsonb)`;
      const worker=new PodcastWorker(database,new S3Client());
      expect(await worker.claim()).toBeUndefined();
      expect((await database`SELECT status,attempts FROM podcast_jobs WHERE id=${id}::uuid`)[0]).toMatchObject({status:"queued",attempts:0});
      await expect(worker.process({id,kind:"bridge",episode_id:null,viewer_did:null,payload_json:{},attempts:1})).rejects.toThrow("Podcast bridge is disabled");
    } finally {
      await database`UPDATE podcast_jobs SET status='complete' WHERE id=${id}::uuid`;
      if(previous===undefined)delete process.env.PODCAST_BRIDGE_ENABLED;else process.env.PODCAST_BRIDGE_ENABLED=previous;
    }
  });
  it("deduplicates shared bridge jobs and prevents duplicate episode GUIDs",async()=>{
    const key=randomUUID();
    for(let i=0;i<2;i++)await database`INSERT INTO podcast_jobs(id,kind,dedupe_key,payload_json) VALUES(${randomUUID()}::uuid,'bridge',${key},'{}'::jsonb) ON CONFLICT(dedupe_key) DO NOTHING`;
    expect((await database`SELECT count(*)::int AS total FROM podcast_jobs WHERE dedupe_key=${key}`)[0].total).toBe(1);
    await database`INSERT INTO podcast_shows(id,source_kind,show_json) VALUES('test-show','rss','{}'::jsonb)`;
    await database`INSERT INTO podcast_episodes(id,show_id,guid,episode_json) VALUES('test-episode','test-show','original-guid','{}'::jsonb)`;
    let rejected=false;
    try { await database`INSERT INTO podcast_episodes(id,show_id,guid,episode_json) VALUES('different-episode','test-show','original-guid','{}'::jsonb)`; } catch {rejected=true;}
    expect(rejected).toBe(true);
  });
  it("rejects cleanup while a clip is published",async()=>{
    const id=randomUUID();
    await database`INSERT INTO podcast_clips(id,viewer_did,episode_id,clip_json,published_uri) VALUES(${id}::uuid,'did:plc:test','test-episode','{}'::jsonb,'at://did:plc:test/app.thesocialwire.podcast.clip/test')`;
    const worker=new PodcastWorker(database,new S3Client());
    await expect(worker.process({id:randomUUID(),kind:"cleanup",episode_id:null,viewer_did:null,payload_json:{clipId:id},attempts:1})).rejects.toThrow("Published clips cannot be cleaned up");
  });
  it("retains canonical protocol identity and enrichment across RSS re-polls",async()=>{
    const transcript={url:"https://example.com/captions.vtt",type:"text/vtt"};
    await database`UPDATE podcast_episodes SET episode_json=${{id:"test-episode",sourceUri:"at://did:plc:publisher/place.pod.episode/first",durationSeconds:42,transcripts:[transcript],chapters:[{startSeconds:0,title:"Intro"}]}}::jsonb WHERE id='test-episode'`;
    await upsertPodcastEpisode(database,{id:"rss-derived-id",showId:"test-show",guid:"original-guid",title:"Updated",publishedAt:new Date(0).toISOString(),audioUrl:"https://example.com/new.mp3",transcripts:[]});
    const row=(await database`SELECT id,episode_json FROM podcast_episodes WHERE show_id='test-show'`)[0];
    expect(row.id).toBe("test-episode");expect(row.episode_json.id).toBe("test-episode");
    expect(row.episode_json.sourceUri).toBe("at://did:plc:publisher/place.pod.episode/first");
    expect(row.episode_json.durationSeconds).toBe(42);expect(row.episode_json.transcripts).toEqual([transcript]);
    expect(row.episode_json.chapters).toEqual([{startSeconds:0,title:"Intro"}]);
    expect(row.episode_json.audioUrl).toBe("https://example.com/new.mp3");
  });
  it("bounds repeated worker crashes but permits explicit queued retries",async()=>{
    await database`UPDATE podcast_jobs SET status='complete' WHERE status='queued'`;
    const id=randomUUID();
    await database`INSERT INTO podcast_jobs(id,kind,dedupe_key,payload_json,status,attempts,lease_until) VALUES(${id}::uuid,'silence',${id},${{sourceFingerprint:"version"}}::jsonb,'running',3,now()-interval '1 minute')`;
    const worker=new PodcastWorker(database,new S3Client());
    expect(await worker.claim()).toBeUndefined();
    expect((await database`SELECT status FROM podcast_jobs WHERE id=${id}::uuid`)[0].status).toBe("failed");
    await database`UPDATE podcast_jobs SET status='queued' WHERE id=${id}::uuid`;
    const retried=await worker.claim();expect(retried?.attempts).toBe(4);
    expect(retried?.payload_json.sourceFingerprint).toBe("version");
  });
});
