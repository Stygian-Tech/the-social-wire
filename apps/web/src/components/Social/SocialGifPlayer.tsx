"use client";

/* eslint-disable @next/next/no-img-element -- GIF posters retain provider formats. */
import { useEffect, useRef, useState } from "react";
import type { GifRendition } from "@/lib/composerMedia";
import { Button } from "@/components/ui/button";

export function SocialGifPlayer({ source, poster, mp4, webm, alt, width, height, files }: { source: string; poster?: string; mp4?: string; webm?: string; alt: string; width?: number; height?: number; files?: Partial<Record<GifRendition, Blob>> }) {
  const [playing, setPlaying] = useState(false);
  const [error, setError] = useState(false);
  const video = useRef<HTMLVideoElement>(null);
  const container = useRef<HTMLDivElement>(null);
  const image = useRef<HTMLImageElement>(null);
  const mp4Source = useRef<HTMLSourceElement>(null);
  const webmSource = useRef<HTMLSourceElement>(null);
  const urls = useRef<Partial<Record<GifRendition, string>>>({});
  const gifBlob = files?.gif, posterBlob = files?.poster, mp4Blob = files?.mp4, webmBlob = files?.webm;
  useEffect(() => {
    const local: Partial<Record<GifRendition, string>> = {};
    for (const [rendition, blob] of [["gif", gifBlob], ["poster", posterBlob], ["mp4", mp4Blob], ["webm", webmBlob]] as const) if (blob) local[rendition] = URL.createObjectURL(blob);
    urls.current = local;
    if (video.current && local.poster) video.current.poster = local.poster;
    if (mp4Source.current && local.mp4) mp4Source.current.src = local.mp4;
    if (webmSource.current && local.webm) webmSource.current.src = local.webm;
    if (image.current && local.poster) image.current.src = local.poster;
    if (video.current && (local.mp4 || local.webm)) video.current.load();
    return () => { Object.values(local).forEach(url => URL.revokeObjectURL(url)); urls.current = {}; };
  }, [gifBlob, posterBlob, mp4Blob, webmBlob]);
  useEffect(() => {
    const uri = playing ? urls.current.gif : urls.current.poster;
    if (image.current && uri) image.current.src = uri;
  }, [playing, gifBlob, posterBlob]);
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
    {mp4 || webm || mp4Blob || webmBlob ? <video ref={video} loop muted playsInline preload="none" poster={poster} aria-label={alt || "Animated GIF"} width={width} height={height} onError={() => { setError(true); setPlaying(false); }} className="block max-h-[60dvh] w-full rounded-xl object-contain" onPause={() => setPlaying(false)}>
      {webm || webmBlob ? <source ref={webmSource} src={webm} type="video/webm" /> : null}{mp4 || mp4Blob ? <source ref={mp4Source} src={mp4} type="video/mp4" /> : null}
    </video> : playing ? <img ref={image} src={source || undefined} alt={alt} width={width} height={height} className="block h-auto max-h-[60dvh] w-full object-contain" onError={() => { setError(true); setPlaying(false); }} /> : poster || posterBlob ? <img ref={image} src={poster} alt={alt} width={width} height={height} className="block h-auto max-h-[60dvh] w-full object-contain" /> : <p className="rounded-xl border p-4 text-sm">Animated GIF · {alt}</p>}
    <div className="flex items-center gap-2"><span className="text-xs font-medium">GIF</span><Button type="button" variant="outline" size="sm" onClick={() => void toggle()} aria-label={playing ? "Pause GIF" : "Play GIF"}>{playing ? "Pause" : "Play"}</Button></div>
    {error ? <p role="alert" className="text-sm text-destructive">GIF Could Not Be Played. Try Again.</p> : null}
  </div>;
}
