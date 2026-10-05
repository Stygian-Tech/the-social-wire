import { SQL } from "bun";
import { createHash } from "node:crypto";
import { podcastGuid, uuidV5 } from "./identity";
import { fetchPublic, publicFeedUrl } from "./publicFetch";
import { probeDuration, withMedia } from "./media";
import type { PodcastEpisode, PodcastShow } from "./types";

interface BridgeCredentials { pds: string; identifier: string; password: string; did: string }
export class PodcastBridge {
  private token?: string;
  constructor(private credentials: BridgeCredentials, private database: SQL) {}

  private async call(method: string, body: object, retry = true): Promise<Record<string, unknown>> {
    if (!this.token) {
      const response = await fetch(`${this.credentials.pds}/xrpc/com.atproto.server.createSession`, {
        method: "POST", headers: {"Content-Type":"application/json"},
        body: JSON.stringify({identifier:this.credentials.identifier,password:this.credentials.password}), signal: AbortSignal.timeout(30_000),
      });
      if(!response.ok) throw new Error("Podcast bridge could not authenticate");
      const session = await response.json() as {accessJwt:string;did:string};
      if(session.did !== this.credentials.did) throw new Error("Podcast bridge DID does not match configured identity");
      this.token = session.accessJwt;
    }
    const response = await fetch(`${this.credentials.pds}/xrpc/${method}`, {method:"POST",headers:{"Content-Type":"application/json",Authorization:`Bearer ${this.token}`},body:JSON.stringify(body),signal:AbortSignal.timeout(30_000)});
    if(response.status === 401 && retry) {this.token = undefined; return this.call(method,body,false);}
    if(!response.ok) throw new Error(`Podcast bridge ${method} failed (${response.status})`);
    return response.json() as Promise<Record<string,unknown>>;
  }

  private async artwork(url: string | undefined): Promise<Record<string, unknown>> {
    if(!url) throw new Error("Bridge publication needs publisher artwork (PNG or JPEG)");
    const response = await fetchPublic(url,5_000_000);
    const mimeType = response.headers.get("content-type")?.split(";")[0];
    if(mimeType !== "image/png" && mimeType !== "image/jpeg") throw new Error("Bridge artwork must be PNG or JPEG; RSS listening remains available");
    // Authenticate before upload. Existing deterministic putRecord is idempotent.
    if(!this.token) await this.authenticate();
    const uploaded = await fetch(`${this.credentials.pds}/xrpc/com.atproto.repo.uploadBlob`, {method:"POST",headers:{"Content-Type":mimeType,Authorization:`Bearer ${this.token}`},body:await response.arrayBuffer(),signal:AbortSignal.timeout(30_000)});
    if(!uploaded.ok) {if(uploaded.status===401)this.token=undefined;throw new Error(`Bridge artwork upload failed (${uploaded.status})`);}
    return (await uploaded.json() as {blob:Record<string,unknown>}).blob;
  }

  private async authenticate(): Promise<void> {
    const response = await fetch(`${this.credentials.pds}/xrpc/com.atproto.server.createSession`, {method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({identifier:this.credentials.identifier,password:this.credentials.password}),signal:AbortSignal.timeout(30_000)});
    if(!response.ok)throw new Error("Podcast bridge could not authenticate");
    const session=await response.json() as {accessJwt:string;did:string};
    if(session.did!==this.credentials.did)throw new Error("Podcast bridge DID does not match configured identity");
    this.token=session.accessJwt;
  }

  private async createdAt(collection:string,rkey:string,otherwise:string):Promise<string> {
    const query=new URLSearchParams({repo:this.credentials.did,collection,rkey});
    const response=await fetch(`${this.credentials.pds}/xrpc/com.atproto.repo.getRecord?${query}`,{signal:AbortSignal.timeout(30_000)});
    if(response.status===404)return otherwise;
    if(response.status===400) {
      const body=await response.json() as {error?:string};
      if(body.error==="RecordNotFound")return otherwise;
      throw new Error("Could not read existing bridge record");
    }
    if(!response.ok)throw new Error("Could not read existing bridge record");
    const body=await response.json() as {value?:{createdAt?:string}};
    return body.value?.createdAt??otherwise;
  }

  async mirror(show: PodcastShow, episodes: PodcastEpisode[]): Promise<{showUri:string;episodes:number}> {
    if(!show.feedUrl)throw new Error("Cannot bridge a show without RSS source");
    publicFeedUrl(show.feedUrl);
    const guid = podcastGuid(show.feedUrl, show.guid);
    const showUri = `at://${this.credentials.did}/org.atpodcasting.podcast/${guid}`;
    const now = new Date().toISOString();
    const createdAt=await this.createdAt("org.atpodcasting.podcast",guid,now);
    const artwork = await this.artwork(show.artworkUrl);
    const publisherShowUri=show.sourceUri&&!show.sourceUri.startsWith(`at://${this.credentials.did}/`)?show.sourceUri:undefined;
    await this.call("com.atproto.repo.putRecord",{repo:this.credentials.did,collection:"org.atpodcasting.podcast",rkey:guid,record:{$type:"org.atpodcasting.podcast",title:show.title.slice(0,500),description:(show.description??"").slice(0,4000),artwork,language:"und",feedUrl:show.feedUrl,categories:[],guid,createdAt}});
    await this.call("com.atproto.repo.putRecord",{repo:this.credentials.did,collection:"app.thesocialwire.podcast.source",rkey:guid,record:{$type:"app.thesocialwire.podcast.source",feedUrl:show.feedUrl,podcastGuid:guid,showUri,bridgeDid:this.credentials.did,publisherShowUri,createdAt,updatedAt:now}});
    await this.database`INSERT INTO podcast_aliases(alias,canonical_id,entity_kind) VALUES(${showUri},${show.id},'show') ON CONFLICT(alias) DO NOTHING`;
    await this.database`INSERT INTO podcast_aliases(alias,canonical_id,entity_kind) VALUES(${"guid:"+guid},${show.id},'show') ON CONFLICT(alias) DO NOTHING`;
    let mirrored = 0;
    for(const episode of episodes) {
      if(!episode.guid)continue; // Never pretend a synthesized identifier came from RSS.
      const rkey=uuidV5(guid,episode.guid);const sourceUri=`at://${this.credentials.did}/org.atpodcasting.episode/${rkey}`;
      const exists=await this.database`SELECT alias FROM podcast_aliases WHERE alias=${sourceUri}`;
      if(exists.length)continue;
      let duration=episode.durationSeconds;
      if(!duration || duration<=0) duration=await withMedia(episode.audioUrl,path=>probeDuration(path));
      await this.call("com.atproto.repo.putRecord",{repo:this.credentials.did,collection:"org.atpodcasting.episode",rkey,record:{$type:"org.atpodcasting.episode",podcast:{podcastGuid:guid,feedUrl:show.feedUrl},title:episode.title.slice(0,500),description:(episode.description??"").slice(0,10000),media:{url:episode.audioUrl,mimeType:episode.audioMimeType??"audio/mpeg"},publishedAt:episode.publishedAt,duration:Math.max(1,Math.round(duration)),feedItemGuid:episode.guid,createdAt:now,transcript:episode.transcripts.map(t=>({url:t.url,mimeType:t.type,...(t.language?{language:t.language}:{})}))}});
      const publisherEpisodeUri=episode.sourceUri&&!episode.sourceUri.startsWith(`at://${this.credentials.did}/`)?episode.sourceUri:undefined;
      await this.call("com.atproto.repo.putRecord",{repo:this.credentials.did,collection:"app.thesocialwire.podcast.source",rkey,record:{$type:"app.thesocialwire.podcast.source",feedUrl:show.feedUrl,podcastGuid:guid,itemGuid:episode.guid,showUri,episodeUri:sourceUri,bridgeDid:this.credentials.did,publisherShowUri,publisherEpisodeUri,createdAt:now,updatedAt:now}});
      await this.database`INSERT INTO podcast_aliases(alias,canonical_id,entity_kind) VALUES(${sourceUri},${episode.id},'episode') ON CONFLICT(alias) DO NOTHING`;
      await this.database`UPDATE podcast_episodes SET episode_json=episode_json || ${{sourceUri:episode.sourceUri&&!episode.sourceUri.startsWith(`at://${this.credentials.did}/`)?episode.sourceUri:sourceUri,durationSeconds:duration}}::jsonb,updated_at=now() WHERE id=${episode.id}`;
      mirrored++;
    }
    await this.database`UPDATE podcast_shows SET show_json=show_json || ${{sourceUri:show.sourceUri&&!show.sourceUri.startsWith(`at://${this.credentials.did}/`)?show.sourceUri:showUri,guid}}::jsonb,updated_at=now() WHERE id=${show.id}`;
    return {showUri,episodes:mirrored};
  }
}

export function provenanceKey(feedUrl: string): string { return createHash("sha256").update(feedUrl).digest("hex"); }
