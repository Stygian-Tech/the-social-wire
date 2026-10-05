"use client";

import { clampPlaybackTime } from "@/lib/podcasts/playback";

export function PodcastSeekBar({ position, duration, seek, label = "Seek Podcast" }: {
  position: number;
  duration: number;
  seek: (seconds: number) => void;
  label?: string;
}) {
  const limit = Number.isFinite(duration) && duration > 0 ? duration : 0;
  const time = limit > 0 ? clampPlaybackTime(position, limit) : 0;
  const progress = limit > 0 ? time / limit * 100 : 0;
  return <div className="relative flex h-6 items-center pointer-coarse:h-11">
    <div aria-hidden="true" className="pointer-events-none absolute inset-x-0 h-0.5 overflow-hidden rounded-full bg-muted">
      <div className="h-full bg-primary" style={{ width: `${progress}%` }} />
    </div>
    <input aria-label={label} type="range" min={0} max={limit} step={0.1}
      value={time} disabled={limit <= 0} onChange={(event) => {
        if (limit > 0) seek(clampPlaybackTime(Number(event.target.value), limit));
      }}
      className="relative m-0 h-full w-full cursor-pointer appearance-none bg-transparent disabled:cursor-default focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring [&::-webkit-slider-runnable-track]:h-0.5 [&::-webkit-slider-runnable-track]:bg-transparent [&::-webkit-slider-thumb]:-mt-[3px] [&::-webkit-slider-thumb]:size-2 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:border-0 [&::-webkit-slider-thumb]:bg-primary [&::-moz-range-track]:h-0.5 [&::-moz-range-track]:bg-transparent [&::-moz-range-thumb]:size-2 [&::-moz-range-thumb]:rounded-full [&::-moz-range-thumb]:border-0 [&::-moz-range-thumb]:bg-primary" />
  </div>;
}
