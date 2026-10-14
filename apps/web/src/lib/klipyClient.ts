import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "./socialWireGatewayClient";
import { gifEmbedURI, klipyMediaURL, type GifAsset } from "./composerMedia";

export async function getComposerGifs(session: OAuthSession, query: { q?: string; cursor?: string; id?: string }, signal?: AbortSignal): Promise<{ results: GifAsset[]; next: string }> {
  const params = new URLSearchParams(Object.entries(query).filter(([, value]) => value !== undefined) as [string, string][]);
  const response = await gatewayFetch(session, `/v1/media/gifs?${params}`, { signal });
  if (!response.ok) throw new Error(response.status === 503 ? "GIF Search Is Not Configured" : response.status === 404 ? "This GIF Is No Longer Available" : response.status === 429 ? "Too Many Searches. Try Again Shortly." : "GIF Search Is Unavailable. Try Again.");
  const body = await response.json() as { results: GifAsset[]; next: string };
  if (!Array.isArray(body.results) || typeof body.next !== "string") throw new Error("Invalid GIF Search Response");
  for (const asset of body.results) { gifEmbedURI(asset); klipyMediaURL(asset.poster); }
  return body;
}

export async function getGifPoster(session: OAuthSession, id: string): Promise<Blob> {
  const response = await gatewayFetch(session, `/v1/media/gifs/thumbnail?${new URLSearchParams({ id })}`, { signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new Error("GIF Preview Could Not Be Prepared. Retry Or Replace The GIF.");
  const blob = await response.blob();
  if (!blob.size || blob.size > 1_000_000 || !["image/jpeg", "image/png", "image/webp"].includes(blob.type)) throw new Error("Invalid GIF Preview");
  return blob;
}
