import { assertDraftAttachmentActor, PRIVATE_DRAFT_FILE_LIMIT, type DraftAttachmentActor } from "./socialDraftAttachmentClient";
import { awaitWithAbort } from "./awaitWithAbort";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "./socialWireGatewayClient";
import { gifEmbedURI, klipyMediaURL, isGifCatalogId, type GifAsset, type GifRendition } from "./composerMedia";

export async function getComposerGifs(session: OAuthSession, query: { q?: string; cursor?: string; id?: string }, signal?: AbortSignal): Promise<{ results: GifAsset[]; next: string }> {
  const params = new URLSearchParams(Object.entries(query).filter(([, value]) => value !== undefined) as [string, string][]);
  const response = await gatewayFetch(session, `/v1/media/gifs?${params}`, { signal });
  if (!response.ok) throw new Error(response.status === 503 ? "GIF Search Is Not Configured" : response.status === 404 ? "This GIF Is No Longer Available" : response.status === 429 ? "Too Many Searches. Try Again Shortly." : "GIF Search Is Unavailable. Try Again.");
  const body = await response.json() as { results: GifAsset[]; next: string };
  if (!Array.isArray(body.results) || typeof body.next !== "string") throw new Error("Invalid GIF Search Response");
  for (const asset of body.results) { gifEmbedURI(asset); klipyMediaURL(asset.poster); }
  return body;
}

/** Retrieve catalog-verified bytes through the fixed authenticated gateway only. */
export async function getGifFile(actor: DraftAttachmentActor, id: string, rendition: GifRendition): Promise<Blob> {
  assertDraftAttachmentActor(actor);
  if (!isGifCatalogId(id) || !["gif", "poster", "mp4", "webm"].includes(rendition)) throw new Error("Reselect This GIF To Privately Sync Its Files.");
  const signal = AbortSignal.any([...(actor.signal ? [actor.signal] : []), AbortSignal.timeout(60_000)]);
  try {
    return await awaitWithAbort((async () => {
      const response = await gatewayFetch(actor.session, `/xrpc/app.thesocialwire.socialDraft.getGifFile?${new URLSearchParams({ id, rendition })}`, { signal, cache: "no-store", redirect: "error" });
      assertDraftAttachmentActor(actor);
      if (!response.ok) throw new Error("GIF Files Could Not Be Copied Privately. Retry Or Reselect The GIF.");
      const blob = await response.blob();
      assertDraftAttachmentActor(actor);
      validateGifFile(blob, rendition);
      return blob;
    })(), signal);
  } finally { assertDraftAttachmentActor(actor); }
}
export function validateGifFile(blob: Blob, rendition: GifRendition) {
  const types = { gif: ["image/gif"], poster: ["image/jpeg", "image/png", "image/webp"], mp4: ["video/mp4"], webm: ["video/webm"] };
  if (!blob.size || blob.size > (rendition === "poster" ? 1_000_000 : PRIVATE_DRAFT_FILE_LIMIT) || !types[rendition].includes(blob.type)) throw new Error("Invalid Private GIF File. Retry Or Reselect The GIF.");
}

export async function getGifPoster(session: OAuthSession, id: string): Promise<Blob> {
  return getGifFile({ session, viewerDid: session.did }, id, "poster");
}
