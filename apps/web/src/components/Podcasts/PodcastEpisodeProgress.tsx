import { clampPlaybackTime, formatPodcastTime } from "@/lib/podcasts/playback";

export function PodcastEpisodeProgress({ position, duration = 0, completed = false }: { position: number; duration?: number; completed?: boolean }) {
  const total = Number.isFinite(duration) && duration > 0 ? duration : 0;
  const elapsed = clampPlaybackTime(position, total);
  if (!elapsed && !completed) return null;
  const percentage = completed ? 100 : total ? elapsed / total * 100 : 0;
  const label = total ? `${formatPodcastTime(elapsed)} / ${formatPodcastTime(total)}` : `${formatPodcastTime(elapsed)} Listened`;
  return <div className="mt-3 space-y-1.5" aria-label="Episode Playback Progress">
    <p className="flex flex-wrap justify-between gap-x-3 text-xs tabular-nums text-muted-foreground"><span>{label}</span>{total && !completed ? <span>{formatPodcastTime(total - elapsed)} Left</span> : null}</p>
    {total ? <div role="progressbar" aria-label="Episode Playback" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(percentage)} aria-valuetext={label} className="h-1 overflow-hidden rounded-full bg-muted"><div className="h-full rounded-full bg-primary" style={{ width: `${percentage}%` }} /></div> : null}
  </div>;
}
