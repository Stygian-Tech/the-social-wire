import type { AppBskyEmbedExternal, AppBskyEmbedImages } from "@atproto/api";
import { socialHttpsUrl } from "./socialUrls";

/** External GIF embeds carry the animation in the URI, not the AppView thumbnail. */
export function socialExternalGif(external: AppBskyEmbedExternal.ViewExternal): AppBskyEmbedImages.ViewImage | undefined {
  const source = [external.uri, external.thumb]
    .map(socialHttpsUrl)
    .find((url) => url && /\.gif$/i.test(new URL(url).pathname));
  if (!source) return undefined;
  const url = new URL(source);
  const width = Number(url.searchParams.get("ww"));
  const height = Number(url.searchParams.get("hh"));
  const validDimensions = Number.isSafeInteger(width) && Number.isSafeInteger(height) && width > 0 && height > 0;
  return {
    thumb: source,
    fullsize: source,
    alt: external.description.replace(/^Alt:\s*/i, "").trim() || external.title,
    ...(validDimensions ? { aspectRatio: { width, height } } : {}),
  };
}
