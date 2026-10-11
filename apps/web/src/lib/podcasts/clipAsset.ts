import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

/** Draft media always uses the authenticated asset route, never its public URL. */
export async function fetchPodcastClipAsset({ session, clipId, format, signal, assertCurrentAccount }: {
  session: OAuthSession; clipId: string; format: "audio" | "video";
  signal?: AbortSignal; assertCurrentAccount?: () => void;
}): Promise<Blob> {
  const check = () => { signal?.throwIfAborted(); assertCurrentAccount?.(); };
  check();
  const response = await gatewayFetch(session, `/v1/podcasts/assets?clipId=${encodeURIComponent(clipId)}&format=${format}`, { signal });
  check();
  if (!response.ok) throw new Error("Clip Media Could Not Load. Please Retry.");
  const blob = await response.blob();
  check();
  if (!blob.size || (format === "video" && !blob.type.toLowerCase().startsWith("video/mp4")))
    throw new Error("Clip Media Is Unavailable. Please Retry Exports.");
  return blob;
}
