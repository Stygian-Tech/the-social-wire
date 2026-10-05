import { createHash } from "node:crypto";

// Podcasting 2.0 namespace; publisher-assigned GUIDs always take precedence.
const PODCAST_NAMESPACE = "ead4c236-bf58-58c6-a2c6-a6b28d128cb6";

export function uuidV5(namespace: string, name: string): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(namespace)) throw new Error("Invalid UUID namespace");
  const digest = createHash("sha1").update(Buffer.from(namespace.replaceAll("-", ""), "hex")).update(name).digest();
  digest[6] = (digest[6]! & 0x0f) | 0x50;
  digest[8] = (digest[8]! & 0x3f) | 0x80;
  const hex = digest.subarray(0, 16).toString("hex");
  return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}

export function podcastGuid(feedUrl: string, supplied?: string): string {
  if (supplied && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(supplied)) return supplied.toLowerCase();
  return uuidV5(PODCAST_NAMESPACE, feedUrl.replace(/^https?:\/\//i, "").replace(/\/+$/, ""));
}

export function mediaVersion(episode: { audioUrl: string; sourceUri?: string }, validator = ""): string {
  return createHash("sha256").update(`${episode.audioUrl}\n${validator}`).digest("hex");
}
