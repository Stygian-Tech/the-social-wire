import { SQL, S3Client } from "bun";
import { randomUUID } from "node:crypto";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { analyzeSilence, probeDuration, renderClip, withMedia } from "./media";
import { downloadPublic } from "./publicFetch";
import { mediaVersion } from "./identity";
import { bridgeEnabled } from "./metadata";
import { PodcastBridge } from "./bridge";
import { pollCatalog } from "./catalog";
import { pollProtocol } from "./protocol";
import type { PodcastEpisode, PodcastJob, PodcastShow, TranscriptCue } from "./types";

export class PodcastWorker {
  readonly id=randomUUID();
  private lastPoll=0;
  constructor(readonly database:SQL,readonly storage:S3Client,readonly bridge?:PodcastBridge) {}

  async claim():Promise<PodcastJob|undefined> {
    await this.database`WITH expired AS (
      UPDATE podcast_jobs SET status='failed',error='Processing lease expired',lease_until=NULL,updated_at=now()
      WHERE status='running' AND lease_until<now() AND attempts>=3 RETURNING kind,payload_json
    ) UPDATE podcast_clips SET clip_json=clip_json || ${{status:"failed",error:"Processing lease expired"}}::jsonb
      FROM expired WHERE expired.kind='clip' AND podcast_clips.id::text=expired.payload_json->>'clipId'`;
    const rows=await this.database`UPDATE podcast_jobs SET status='running',attempts=attempts+1,worker_id=${this.id},lease_until=now()+interval '2 minutes',updated_at=now()
      WHERE id=(SELECT id FROM podcast_jobs WHERE ((status='queued' AND available_at<=now()) OR (status='running' AND lease_until<now())) AND (kind<>'bridge' OR ${bridgeEnabled()}) ORDER BY available_at,id FOR UPDATE SKIP LOCKED LIMIT 1) RETURNING *`;
    return rows[0] as PodcastJob|undefined;
  }

  async tick():Promise<void> {
    const job=await this.claim();
    if(job)await this.execute(job);
    if(Date.now()-this.lastPoll>900_000) {this.lastPoll=Date.now();await this.pollSubscriptions();}
  }

  private async pollSubscriptions():Promise<void> {
    const shows=await this.database`SELECT DISTINCT s.id,s.show_json FROM podcast_shows s JOIN podcast_subscriptions sub ON sub.show_id=s.id ORDER BY s.id`;
    for(const row of shows) {
      try {
        const show=row.show_json as PodcastShow;
        if(show.sourceUri&&!show.sourceUri.startsWith(`at://${process.env.PODCAST_BRIDGE_DID}/`))await pollProtocol(this.database,show);
        const episodes=show.feedUrl?await pollCatalog(this.database,show):[];
        if(bridgeEnabled()&&this.bridge&&show.sourceKind==="rss"&&show.feedUrl) {
          // Queue publication, never perform repository writes in feed-serving requests.
          const key=`bridge:${row.id}:${mediaVersion({audioUrl:JSON.stringify(episodes.map(e=>e.id))})}`;
          await this.database`INSERT INTO podcast_jobs(id,kind,dedupe_key,payload_json) VALUES(${randomUUID()}::uuid,'bridge',${key},${{showId:row.id,feedUrl:(row.show_json as PodcastShow).feedUrl}}::jsonb) ON CONFLICT(dedupe_key) DO NOTHING`;
        }
      } catch(error) {console.error(JSON.stringify({event:"podcast_poll_failed",showId:row.id,error:safeError(error)}));}
    }
  }

  private async execute(job:PodcastJob):Promise<void> {
    let leaseLost=false;
    const heartbeat=setInterval(()=>void this.database`UPDATE podcast_jobs SET lease_until=now()+interval '2 minutes' WHERE id=${job.id}::uuid AND worker_id=${this.id} AND status='running' RETURNING id`.then(rows=>{if(!rows.length)leaseLost=true;}).catch(()=>{leaseLost=true;}),30_000);
    try {
      const result=await this.process(job);
      if(leaseLost)throw new Error("Media job lease lost");
      await this.database.begin(async transaction=>{
        const rows=await transaction`UPDATE podcast_jobs SET status='complete',result_json=${result}::jsonb,error=NULL,lease_until=NULL,updated_at=now() WHERE id=${job.id}::uuid AND worker_id=${this.id} AND status='running' RETURNING id`;
        if(rows.length && job.kind==="clip")await transaction`UPDATE podcast_clips SET clip_json=clip_json || ${{...result,status:"complete"}}::jsonb,updated_at=now() WHERE id=${String(job.payload_json.clipId)}::uuid`;
      });
    } catch(error) {
      const failed=job.attempts>=3;
      await this.database`UPDATE podcast_jobs SET status=${failed?"failed":"queued"},error=${safeError(error)},lease_until=NULL,available_at=now()+interval '1 minute',updated_at=now() WHERE id=${job.id}::uuid AND worker_id=${this.id} AND status='running'`;
      if(failed && job.kind==="clip")await this.database`UPDATE podcast_clips SET clip_json=clip_json || ${{status:"failed",error:safeError(error)}}::jsonb WHERE id=${String(job.payload_json.clipId)}::uuid`;
    } finally {clearInterval(heartbeat);}
  }

  async process(job:PodcastJob):Promise<Record<string,unknown>> {
    if(job.kind==="bridge") {
      if(!bridgeEnabled())throw new Error("Podcast bridge is disabled");
      if(!this.bridge)throw new Error("Podcast bridge credentials are not configured");
      const showId=String(job.payload_json.showId);
      const subscribed=await this.database`SELECT show_id FROM podcast_subscriptions WHERE show_id=${showId} LIMIT 1`;
      if(!subscribed.length)return {skipped:true,reason:"No active subscriptions"};
      const rows=await this.database`SELECT show_json FROM podcast_shows WHERE id=${showId}`;
      if(!rows.length)throw new Error("Podcast show not found");
      const episodes=await this.database`SELECT episode_json FROM podcast_episodes WHERE show_id=${showId} ORDER BY published_at,id`;
      return this.bridge.mirror(rows[0].show_json as PodcastShow,episodes.map((e:{episode_json:PodcastEpisode})=>e.episode_json));
    }
    if(job.kind==="cleanup") {
      const clipId=String(job.payload_json.clipId??job.payload_json.id);
      // Derive keys from validated clip ID; never delete arbitrary supplied storage keys.
      if(!/^[0-9a-f-]{36}$/i.test(clipId))throw new Error("Invalid clip ID");
      const rows=await this.database`SELECT published_uri FROM podcast_clips WHERE id=${clipId}::uuid`;
      if(rows[0]?.published_uri)throw new Error("Published clips cannot be cleaned up");
      for(const name of ["audio.m4a","audiogram.mp4"])await this.storage.file(`clips/${clipId}/${name}`).delete();
      return {deleted:true};
    }
    const episode=job.payload_json.episode as PodcastEpisode|undefined;
    if(!episode?.audioUrl)throw new Error("Media job missing episode");
    return withMedia(episode.audioUrl,async(path,directory,validator)=>{
      const duration=await probeDuration(path);
      if(job.kind==="silence") {
        const knownValidator=validator.split("|").slice(0,2).some(Boolean);
        const sourceFingerprint=knownValidator?createHash("sha256").update(`${episode.audioUrl}|${validator}`).digest("hex"):job.payload_json.sourceFingerprint;
        return {analysisVersion:"v2",intervals:await analyzeSilence(path,duration),mediaVersion:mediaVersion(episode,validator),sourceFingerprint,durationSeconds:duration};
      }
      if(job.kind!=="clip")throw new Error("Unsupported media job kind");
      const clipId=String(job.payload_json.clipId);if(!/^[0-9a-f-]{36}$/i.test(clipId))throw new Error("Invalid clip ID");
      const show=job.payload_json.show as PodcastShow;
      let artwork:string|undefined;
      if(episode.artworkUrl??show?.artworkUrl) {artwork=join(directory,"artwork.image");await downloadPublic((episode.artworkUrl??show.artworkUrl)!,artwork,5_000_000);}
      const cues=(job.payload_json.cues as TranscriptCue[]|undefined)??episode.transcripts.flatMap(t=>t.cues??[]);
      const files=await renderClip({source:path,directory,start:Math.round(Number(job.payload_json.startSeconds)*1000)/1000,end:Math.round(Number(job.payload_json.endSeconds)*1000)/1000,duration,artwork,title:String(job.payload_json.title??episode.title),attribution:show?.title??"Podcast",cues});
      const audioKey=`clips/${clipId}/audio.m4a`;const videoKey=`clips/${clipId}/audiogram.mp4`;
      await this.storage.file(audioKey).write(Bun.file(files.audio),{type:"audio/mp4"});
      await this.storage.file(videoKey).write(Bun.file(files.video),{type:"video/mp4"});
      const publicBase=(process.env.PODCAST_PUBLIC_GATEWAY_URL??"https://api.thesocialwire.app").replace(/\/$/,"");
      return {audioKey,videoKey,publicAudioUrl:`${publicBase}/v1/podcasts/public/assets?clipId=${clipId}&format=audio`,publicVideoUrl:`${publicBase}/v1/podcasts/public/assets?clipId=${clipId}&format=video`,audioUrl:`/v1/podcasts/assets?clipId=${clipId}&format=audio`,videoUrl:`/v1/podcasts/assets?clipId=${clipId}&format=video`,durationSeconds:Number(job.payload_json.endSeconds)-Number(job.payload_json.startSeconds)};
    });
  }
}

function safeError(error:unknown):string {
  // Never include publisher URLs with credentials or bridge tokens in job/log output.
  return (error instanceof Error?error.message:"Podcast processing failed").replace(/https?:\/\/\S+/g,"[publisher]").slice(0,300);
}
