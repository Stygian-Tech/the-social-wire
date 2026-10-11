export type StreamBlob = { $type: "blob"; ref: { $link: string }; mimeType: string; size: number };
export type LivestreamRecord = { $type: "place.stream.livestream"; title: string; createdAt: string; endedAt?: string; lastSeenAt?: string; tags?: string[]; thumb?: StreamBlob; url?: string; canonicalUrl?: string; [key: string]: unknown };
export type Livestream = { uri: string; cid: string; record: LivestreamRecord };
export type LivestreamInput = { title: string; tags: string[]; thumb?: StreamBlob };
export type StreamKey = { secret: string; signingKey: string; uri: string };
export type StreamChatMessage = { uri: string; cid: string; author: { did: string; handle: string; displayName?: string }; record: { $type: "place.stream.chat.message"; text: string; streamer: string; createdAt: string }; indexedAt?: string };
export type StreamSnapshot = { stream?: Livestream; messages: StreamChatMessage[]; viewers?: number; totalSessions?: number; connected: boolean; error?: string };
export type StreamOperation = { rkey: string; createdAt: string; assertCurrentAccount?: () => void };
export type StreamIngest = { type: "rtmp" | "rtmps" | "whip"; url: string };
