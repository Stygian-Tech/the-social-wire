"use client";

/* eslint-disable @next/next/no-img-element -- GIF posters retain provider formats. */
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";

export function SocialGifPlayer({ source, poster, mp4, webm, alt, width, height }: { source: string; poster?: string; mp4?: string; webm?: string; alt: string; width?: number; height?: number }) {
  const [playing, setPlaying] = useState(false);
  const [error, setError] = useState(false);
  const video = useRef<HTMLVideoElement>(null);
  const container = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const element = container.current;
    if (!element || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(entries => { if (!entries[0].isIntersecting) { video.current?.pause(); setPlaying(false); } });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);
  async function toggle() {
    setError(false);
    if (playing) { video.current?.pause(); setPlaying(false); return; }
    if (video.current) { try { await video.current.play(); setPlaying(true); } catch { setError(true); } }
    else setPlaying(true);
  }
  return <div ref={container} className="flex min-w-0 flex-col gap-2">
    {mp4 || webm ? <video ref={video} loop muted playsInline preload="none" poster={poster} aria-label={alt || "Animated GIF"} width={width} height={height} onError={() => { setError(true); setPlaying(false); }} className="block max-h-[60dvh] w-full rounded-xl object-contain" onPause={() => setPlaying(false)}>
      {webm ? <source src={webm} type="video/webm" /> : null}{mp4 ? <source src={mp4} type="video/mp4" /> : null}
    </video> : playing ? <img src={source} alt={alt} width={width} height={height} className="block h-auto max-h-[60dvh] w-full object-contain" onError={() => { setError(true); setPlaying(false); }} /> : poster ? <img src={poster} alt={alt} width={width} height={height} className="block h-auto max-h-[60dvh] w-full object-contain" /> : <p className="rounded-xl border p-4 text-sm">Animated GIF · {alt}</p>}
    <div className="flex items-center gap-2"><span className="text-xs font-medium">GIF</span><Button type="button" variant="outline" size="sm" onClick={() => void toggle()} aria-label={playing ? "Pause GIF" : "Play GIF"}>{playing ? "Pause" : "Play"}</Button></div>
    {error ? <p role="alert" className="text-sm text-destructive">GIF Could Not Be Played. Try Again.</p> : null}
  </div>;
}
