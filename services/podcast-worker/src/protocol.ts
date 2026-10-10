import { chapters, safeUrl } from "./metadata";
import type { SQL } from "bun";
import { fetchPublic } from "./publicFetch";
import type { PodcastEpisode, PodcastShow, TranscriptReference } from "./types";

const collections:Record<string,string>={"org.atpodcasting.podcast":"org.atpodcasting.episode","place.pod.show":"place.pod.episode","live.voxport.podcast.series":"live.voxport.podcast.episode"};
const object=(value:unknown):Record<string,unknown>=>value&&typeof value==="object"?value as Record<string,unknown>:{};
const text=(value:unknown)=>typeof value==="string"?value:undefined;

export async function resolvePds(did:string):Promise<string> {
  let url:string;
  if(did.startsWith("did:plc:"))url=`https://plc.directory/${encodeURIComponent(did)}`;
  else if(did.startsWith("did:web:")) {
    const parts=did.slice(8).split(":").map(decodeURIComponent);const host=parts.shift()!;
    url=`https://${host}/${parts.length?parts.map(encodeURIComponent).join("/"):".well-known"}/did.json`;
  } else throw new Error("Unsupported podcast DID");
  const document=await (await fetchPublic(url)).json() as {service?:Array<{id:string;type:string;serviceEndpoint:unknown}>};
  const service=document.service?.find(service=>service.id.endsWith("#atproto_pds")&&service.type==="AtprotoPersonalDataServer");
  if(typeof service?.serviceEndpoint!=="string")throw new Error("Podcast PDS discovery failed");
  return service.serviceEndpoint.replace(/\/$/,"");
}

export function protocolEpisode(uri:string,record:Record<string,unknown>,show:PodcastShow,pds:string):PodcastEpisode|undefined {
  const parent=show.sourceUri?.match(/^at:\/\/([^/]+)\/([^/]+)\/(.+)$/);if(!parent)return;
  const family=parent[2]!;
  if(family==="org.atpodcasting.podcast") {if(!show.guid||object(record.podcast).podcastGuid!==show.guid)return;}
  else if((record.showUri??object(record.series).uri)!==show.sourceUri)return;
  // Unpublished VoxPort episodes must never enter a public listener catalog.
  if(family==="live.voxport.podcast.series"&&!text(record.publishedAt))return;
  const media=object(record.media);const blob=object(record.audio);const cid=text(object(blob.ref).$link);
  const audio=text(media.url??record.audioUrl)??(cid?`${pds}/xrpc/com.atproto.sync.getBlob?did=${encodeURIComponent(parent[1]!)}&cid=${encodeURIComponent(cid)}`:undefined);
  const mime=text(media.mimeType??record.audioMimeType??record.audioType??blob.mimeType);
  if(!audio||!mime?.startsWith("audio/")||!text(record.title))return;
  const refs=record.transcripts??record.transcript;
  const transcripts:TranscriptReference[]=(Array.isArray(refs)?refs:refs?[refs]:[]).flatMap(value=>{const item=object(value);return text(item.url)?[{url:text(item.url)!,type:text(item.type??item.mimeType)??"text/plain",language:text(item.language)}]:[];});
  if(text(record.transcriptUrl))transcripts.push({url:text(record.transcriptUrl)!,type:text(record.transcriptMimeType)??"text/plain"});
  const duration=Number(record.durationSeconds??record.duration);
  return {id:uri,sourceUri:uri,showId:show.id,title:text(record.title)!,description:text(record.description??record.summary),publishedAt:text(record.publishedAt??record.createdAt)??new Date(0).toISOString(),audioUrl:audio,audioMimeType:mime,durationSeconds:Number.isFinite(duration)&&duration>0?duration:undefined,artworkUrl:text(record.imageUrl)??show.artworkUrl,guid:text(record.feedItemGuid??record.guid??record.importedGuid),transcripts,chapters:chapters(record.chapters,Number.isFinite(duration)?duration:undefined),chapterSourceUrl:safeUrl(record.chaptersUrl??object(record.chapters).url),showArtworkUrl:show.artworkUrl};
}

export async function pollProtocol(database:SQL,show:PodcastShow):Promise<void> {
  const parent=show.sourceUri?.match(/^at:\/\/([^/]+)\/([^/]+)\/(.+)$/);if(!parent||!collections[parent[2]!])return;
  const pds=await resolvePds(parent[1]!);let cursor:string|undefined;const visited=new Set<string>();
  do {
    const query=new URLSearchParams({repo:parent[1]!,collection:collections[parent[2]!]!,limit:"100",...(cursor?{cursor}:{})});
    const page=await (await fetchPublic(`${pds}/xrpc/com.atproto.repo.listRecords?${query}`)).json() as {records:Array<{uri:string;value:Record<string,unknown>}>;cursor?:string};
    for(const row of page.records) {
      const episode=protocolEpisode(row.uri,row.value,show,pds);if(!episode)continue;
      const matching=episode.guid?await database`SELECT id FROM podcast_episodes WHERE show_id=${show.id} AND guid=${episode.guid}`:[];
      if(matching.length)episode.id=matching[0].id;
      await database`INSERT INTO podcast_episodes(id,show_id,guid,episode_json,published_at) VALUES(${episode.id},${show.id},${episode.guid??null},${episode}::jsonb,${episode.publishedAt}::timestamptz) ON CONFLICT(id) DO UPDATE SET episode_json=EXCLUDED.episode_json || jsonb_build_object('chapters',CASE WHEN jsonb_array_length(COALESCE(EXCLUDED.episode_json->'chapters','[]'::jsonb))=0 AND EXCLUDED.episode_json->>'chapterSourceUrl' IS NOT DISTINCT FROM podcast_episodes.episode_json->>'chapterSourceUrl' THEN COALESCE(podcast_episodes.episode_json->'chapters','[]'::jsonb) ELSE EXCLUDED.episode_json->'chapters' END),updated_at=now()`;
      await database`INSERT INTO podcast_aliases(alias,canonical_id,entity_kind) VALUES(${row.uri},${episode.id},'episode') ON CONFLICT(alias) DO NOTHING`;
    }
    cursor=page.cursor;if(cursor&&visited.has(cursor))throw new Error("Podcast PDS cursor repeated");if(cursor)visited.add(cursor);
  } while(cursor);
}
