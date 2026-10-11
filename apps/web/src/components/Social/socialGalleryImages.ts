import type { AppBskyEmbedImages } from "@atproto/api";
import { socialHttpsUrl } from "./socialUrls";

/** Bridge the current gallery schema until the installed SDK includes its generated types. */
export function socialGalleryImages(embed: unknown): AppBskyEmbedImages.ViewImage[] | undefined {
  if (!embed || typeof embed !== "object" || !("$type" in embed) || embed.$type !== "app.bsky.embed.gallery#view") return undefined;
  if (!("items" in embed) || !Array.isArray(embed.items)) return [];
  return embed.items.slice(0, 20).flatMap((item: unknown) => {
    if (!item || typeof item !== "object" || !("$type" in item) || item.$type !== "app.bsky.embed.gallery#viewImage") return [];
    if (!("thumbnail" in item) || !("fullsize" in item) || !("alt" in item) || typeof item.alt !== "string") return [];
    const thumb = socialHttpsUrl(item.thumbnail);
    const fullsize = socialHttpsUrl(item.fullsize);
    if (!thumb || !fullsize) return [];
    const ratio = "aspectRatio" in item ? item.aspectRatio : undefined;
    const validRatio = ratio && typeof ratio === "object" && "width" in ratio && "height" in ratio && typeof ratio.width === "number" && typeof ratio.height === "number" && Number.isSafeInteger(ratio.width) && Number.isSafeInteger(ratio.height) && ratio.width > 0 && ratio.height > 0;
    return [{ thumb, fullsize, alt: item.alt, ...(validRatio ? { aspectRatio: { width: ratio.width as number, height: ratio.height as number } } : {}) }];
  });
}
