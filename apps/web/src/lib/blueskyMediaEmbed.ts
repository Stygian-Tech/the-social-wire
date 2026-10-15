import { AppBskyEmbedExternal, AppBskyEmbedImages } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "./atprotoClient";
import { gifEmbedURI, mediaReady, type ComposerMedia } from "./composerMedia";
import { getComposerGifs, getGifPoster } from "./klipyClient";
import { isMissingOAuthScope, SCOPE_RECOVERY_MESSAGE } from "./oauthScopeRecovery";

export async function composeMediaEmbed(session: OAuthSession, media: ComposerMedia, assertCurrentAccount?: () => void, onProgress?: (message: string) => void) {
  if (!mediaReady(media)) throw new Error("Finish Preparing Attachments Before Posting");
  const agent = createOAuthAgent(session);
  if (media.kind === "photos") {
    const images: AppBskyEmbedImages.Image[] = [];
    for (const [index, photo] of media.photos.entries()) {
      assertCurrentAccount?.();
      onProgress?.(`Uploading Photo ${index + 1} Of ${media.photos.length}…`);
      const blob = photo.blob!;
      if (blob.size > 2_000_000 || !["image/jpeg", "image/png"].includes(blob.type)) throw new Error("Invalid Prepared Photo");
      const result = await agent.uploadBlob(blob).catch(error => {
        if (isMissingOAuthScope(error)) throw new Error(SCOPE_RECOVERY_MESSAGE);
        throw new Error(`Photo ${index + 1} Could Not Be Uploaded. Retry Or Remove This Photo.`);
      });
      assertCurrentAccount?.();
      if (result.data.blob.size !== blob.size || result.data.blob.mimeType !== blob.type) throw new Error("Photo Upload Could Not Be Verified");
      images.push({ image: result.data.blob, alt: photo.alt.trim(), aspectRatio: { width: photo.width!, height: photo.height! } });
    }
    const embed = { $type: "app.bsky.embed.images" as const, images };
    if (!AppBskyEmbedImages.validateMain(embed).success) throw new Error("Invalid Photo Attachment");
    return embed;
  }
  onProgress?.("Preparing GIF…");
  // Re-resolve provider identity instead of trusting stale draft URLs.
  const resolved = await getComposerGifs(session, { id: media.asset.id });
  assertCurrentAccount?.();
  const asset = resolved.results.find(item => item.id === media.asset.id);
  if (!asset) throw new Error("This GIF Is No Longer Available. Replace Or Remove It.");
  const poster = await getGifPoster(session, asset.id);
  assertCurrentAccount?.();
  onProgress?.("Uploading GIF Preview…");
  const uploaded = await agent.uploadBlob(poster).catch(error => {
    if (isMissingOAuthScope(error)) throw new Error(SCOPE_RECOVERY_MESSAGE);
    throw new Error("GIF Preview Could Not Be Uploaded. Retry Or Replace The GIF.");
  });
  assertCurrentAccount?.();
  if (uploaded.data.blob.size !== poster.size || uploaded.data.blob.mimeType !== poster.type) throw new Error("GIF Preview Upload Could Not Be Verified");
  const preferred = media.alt.trim();
  if (preferred.length > 2000) throw new Error("GIF Description Exceeds The Size Limit");
  const external = { uri: gifEmbedURI(asset), title: asset.title || asset.description || "GIF", description: preferred ? `Alt: ${preferred}` : `ALT: ${asset.description || asset.title}`, thumb: uploaded.data.blob };
  const embed = { $type: "app.bsky.embed.external" as const, external };
  if (!AppBskyEmbedExternal.validateMain(embed).success) throw new Error("Invalid GIF Attachment");
  return embed;
}
