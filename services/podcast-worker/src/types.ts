export interface PodcastChapter {startSeconds:number;title:string;artworkUrl?:string;url?:string}
export interface PodcastPerson {name:string;role?:string;imageUrl?:string;url?:string}
export interface PodcastShow {
  id: string;
  title: string;
  description?: string;
  artworkUrl?: string;
  feedUrl?: string;
  sourceKind: "rss" | "atproto";
  sourceUri?: string;
  guid?: string;
  hosts?: PodcastPerson[];
}

export interface TranscriptCue { startSeconds: number; endSeconds?: number; text: string }
export interface TranscriptReference { url: string; type: string; language?: string; cues?: TranscriptCue[] }
export interface PodcastEpisode {
  id: string; showId: string; title: string; description?: string;
  publishedAt: string; audioUrl: string; audioMimeType?: string;
  durationSeconds?: number; artworkUrl?: string; guid?: string;
  sourceUri?: string; transcripts: TranscriptReference[];
  chapters?: PodcastChapter[]; chapterSourceUrl?: string; showArtworkUrl?: string;
}

export interface PodcastJob {
  id: string; kind: "bridge" | "silence" | "clip" | "transcript" | "cleanup";
  viewer_did: string | null; episode_id: string | null;
  payload_json: Record<string, unknown>; attempts: number;
}

export interface SilenceInterval { start: number; end: number }
