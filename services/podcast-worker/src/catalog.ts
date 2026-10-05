import Parser from "rss-parser";
import { createHash } from "node:crypto";
import type { SQL } from "bun";
import { fetchPublic, publicUrl, publicFeedUrl } from "./publicFetch";
import type { PodcastEpisode, PodcastShow, TranscriptReference } from "./types";

const hash=(value:string)=>createHash("sha256").update(value).digest("hex");
type PodcastItemExtras = {itunes?: {duration?: string; image?: string}; podcastTranscripts?: Array<{$?:{url?:string;type?:string;language?:string}}>};
const parser = new Parser<{"podcast:guid"?: string}, PodcastItemExtras>({customFields:{feed:["podcast:guid"],item:[["podcast:transcript","podcastTranscripts",{keepArray:true}]]}});

export function seconds(raw: unknown): number | undefined {
  if(typeof raw!=="string" && typeof raw!=="number")return undefined;
  const parts=String(raw).split(":").map(Number);
  if(parts.some(n=>!Number.isFinite(n) || n<0))return undefined;
  const duration=parts.reduce((total,n)=>total*60+n,0);
  return duration>0?duration:undefined;
}

export async function parsePodcast(xml:string,feedUrl:string,existing?:PodcastShow):Promise<{show:PodcastShow;episodes:PodcastEpisode[]}> {
  const parsed = await parser.parseString(xml);
  const supplied=parsed["podcast:guid"]?.trim();
  const id=existing?.id??`podcast:${hash(supplied??feedUrl)}`;
  const show:PodcastShow={id,title:parsed.title??"Podcast",description:parsed.description,feedUrl,sourceKind:existing?.sourceKind??"rss",guid:supplied??existing?.guid,artworkUrl:parsed.itunes?.image??parsed.image?.url??existing?.artworkUrl,sourceUri:existing?.sourceUri};
  const episodes:PodcastEpisode[]=[];
  for(const item of parsed.items) {
    const audio=item.enclosure?.url;
    if(!audio || !(item.enclosure?.type??"").startsWith("audio/"))continue;
    try {publicUrl(audio);}catch{continue;}
    const guid=item.guid??audio;
    const extra=item as typeof item & {podcastTranscripts?:Array<{$?:{url?:string;type?:string;language?:string}}>};
    const transcripts:TranscriptReference[]=(extra.podcastTranscripts??[]).flatMap(t=>t.$?.url&&t.$.type?[{url:t.$.url,type:t.$.type,language:t.$.language}]:[]);
    const date = new Date(item.isoDate??item.pubDate??0);
    episodes.push({id:`episode:${hash(`${id}|${guid}`)}`,showId:id,title:item.title??"Episode",description:item.content??item.contentSnippet,publishedAt:Number.isNaN(date.getTime())?new Date(0).toISOString():date.toISOString(),audioUrl:audio,audioMimeType:item.enclosure?.type,durationSeconds:seconds(item.itunes?.duration),artworkUrl:item.itunes?.image??show.artworkUrl,guid,transcripts});
  }
  return {show,episodes};
}

export async function pollCatalog(database:SQL,show:PodcastShow):Promise<PodcastEpisode[]> {
  if(!show.feedUrl)return [];
  const response=await fetchPublic(show.feedUrl,16*1024*1024,5,publicFeedUrl);
  const parsed=await parsePodcast(await response.text(),show.feedUrl,show);
  await database`UPDATE podcast_shows SET show_json=${parsed.show}::jsonb,updated_at=now() WHERE id=${show.id}`;
  for(const episode of parsed.episodes) {
    await upsertPodcastEpisode(database,episode);
  }
  return parsed.episodes;
}

export async function upsertPodcastEpisode(database:SQL,episode:PodcastEpisode):Promise<void> {
    // Identity is stable; retain enriched protocol references when RSS updates.
    await database`INSERT INTO podcast_episodes(id,show_id,guid,episode_json,published_at) VALUES(${episode.id},${episode.showId},${episode.guid??null},${episode}::jsonb,${episode.publishedAt}::timestamptz)
      ON CONFLICT(show_id,guid) WHERE guid IS NOT NULL DO UPDATE SET episode_json=EXCLUDED.episode_json || jsonb_strip_nulls(jsonb_build_object(
        'id',podcast_episodes.id,
        'sourceUri',podcast_episodes.episode_json->'sourceUri',
        'durationSeconds',COALESCE(EXCLUDED.episode_json->'durationSeconds',podcast_episodes.episode_json->'durationSeconds'),
        'transcripts',CASE WHEN jsonb_array_length(EXCLUDED.episode_json->'transcripts')=0 THEN podcast_episodes.episode_json->'transcripts' ELSE EXCLUDED.episode_json->'transcripts' END
      )),updated_at=now()`;
}
