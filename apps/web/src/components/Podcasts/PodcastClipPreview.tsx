"use client";
export function PodcastClipPreview({ url, title, onPlay, onError }: { url: string; title: string; onPlay: () => void; onError?: () => void }) {
  return <video aria-label={`Video Preview: ${title}`} src={url} controls playsInline preload="metadata"
    data-podcast-clip-preview onError={onError} onPlay={event => {
      for (const video of document.querySelectorAll<HTMLVideoElement>("video[data-podcast-clip-preview]"))
        if (video !== event.currentTarget && !video.paused) video.pause();
      onPlay();
    }} className="mx-auto max-h-[min(65dvh,640px)] w-full rounded-xl bg-black object-contain">
    Your Browser Does Not Support Video Playback.
  </video>;
}
