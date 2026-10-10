import { fetchPublicPodcastClip } from "@/lib/podcasts/publicClip";
import { podcastsEnabled } from "@/lib/podcasts/playback";
export async function GET(request: Request) {
  if (!podcastsEnabled()) return new Response(null, { status: 404 });
  const params = new URL(request.url).searchParams;
  let url: URL;
  try {
    url = new URL(params.get("url") ?? "");
  } catch {
    return Response.json({ error: "Invalid Clip URL" }, { status: 400 });
  }
  const origin = new URL(
    process.env.NEXT_PUBLIC_SITE_URL ?? "https://thesocialwire.app",
  ).origin;
  const match = /^\/podcast-clips\/([^/]+)$/.exec(url.pathname);
  if (url.origin !== origin || !match)
    return Response.json({ error: "Unknown Clip URL" }, { status: 404 });
  const clip = await fetchPublicPodcastClip(decodeURIComponent(match[1]));
  if (!clip) return new Response(null, { status: 404 });
  const width = Math.min(
    640,
    Math.max(200, Number(params.get("maxwidth")) || 480),
  );
  return Response.json({
    version: "1.0",
    type: "rich",
    title: clip.title,
    provider_name: "The Social Wire",
    provider_url: origin,
    width,
    height: 200,
    html: `<iframe src="${origin}/podcast-clips/${encodeURIComponent(clip.id)}/embed" width="${width}" height="200" title="Podcast Clip" loading="lazy" allow="autoplay"></iframe>`,
  });
}
