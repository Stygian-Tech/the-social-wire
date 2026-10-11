"use client";
import { useEffect, useRef, useState } from "react";
import type Hls from "hls.js";
import { loadSocialVideoHls } from "@/lib/socialVideoPlayback";
import { streamplacePublicUrl } from "@/lib/livestream/streamplaceNode";
export function LivestreamPreview({ node, did }: { node: string; did: string }) {
  const ref = useRef<HTMLVideoElement>(null), [error, setError] = useState(false);
  useEffect(() => {
    let disposed = false, engine: Hls | undefined; const video = ref.current;
    const url = streamplacePublicUrl(node, `/xrpc/place.stream.playback.getLivePlaylist?${new URLSearchParams({ streamer: did })}`);
    void loadSocialVideoHls().then(Hls => { if (disposed || !video) return; if (Hls.isSupported()) { engine = new Hls({ maxBufferLength: 10, backBufferLength: 10 }); engine.on(Hls.Events.ERROR, (_event, data) => { if (data.fatal && !disposed) setError(true); }); engine.loadSource(url); engine.attachMedia(video); } else if (video.canPlayType("application/vnd.apple.mpegurl")) video.src = url; else setError(true); }).catch(() => { if (!disposed) setError(true); });
    return () => { disposed = true; engine?.destroy(); video?.removeAttribute("src"); };
  }, [node, did]);
  return <div><video ref={ref} controls playsInline aria-label="Livestream Preview" poster={streamplacePublicUrl(node, `/api/playback/${encodeURIComponent(did)}/stream.jpg`)} className="w-full rounded-xl bg-black" onError={() => setError(true)} />{error ? <p role="status">No Live Playback Is Available On This Node.</p> : null}</div>;
}
