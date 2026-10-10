export const PODCAST_SPEEDS = Array.from(
  { length: 6 },
  (_, index) => 0.75 + index * 0.25,
);
export const podcastsEnabled = () =>
  process.env.NEXT_PUBLIC_PODCASTS_ENABLED === "true";
export type SilenceInterval = { start: number; end: number };
export type TranscriptCue = { start: number; end: number; text: string };
export function clampPlaybackTime(time: number, duration: number): number {
  return Math.min(
    Math.max(0, Number.isFinite(time) ? time : 0),
    Number.isFinite(duration) && duration > 0
      ? duration
      : Number.MAX_SAFE_INTEGER,
  );
}
/** Skip only the interior of a confirmed silence, preserving publisher timestamps. */
export function silenceSkipTarget(
  time: number,
  intervals: readonly SilenceInterval[],
  duration: number,
): number | null {
  const interval = intervals.find(
    (item) =>
      Number.isFinite(item.start) &&
      Number.isFinite(item.end) &&
      item.end > item.start &&
      time >= item.start &&
      time < item.end - 0.03,
  );
  return interval ? clampPlaybackTime(interval.end, duration) : null;
}
export function activeTranscriptCue(
  cues: readonly TranscriptCue[],
  time: number,
): number {
  return cues.findIndex((cue) => time >= cue.start && time < cue.end);
}
export function formatPodcastTime(time: number): string {
  const seconds = Math.floor(Math.max(0, Number.isFinite(time) ? time : 0));
  const hours = Math.floor(seconds / 3600);
  return `${hours ? `${hours}:` : ""}${String(Math.floor(seconds / 60) % 60).padStart(hours ? 2 : 1, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}
export function validateClipBounds(
  start: number,
  end: number,
  duration: number,
): boolean {
  return (
    Number.isFinite(start) &&
    Number.isFinite(end) &&
    start >= 0 &&
    end > start &&
    end <= duration &&
    end - start <= 600
  );
}

/** Normalize persisted legacy preferences to the current supported quarter-speed steps. */
export function normalizePodcastSpeed(speed: number): number {
  if (!Number.isFinite(speed)) return 1;
  return Math.min(2, Math.max(0.75, Math.round(speed * 4) / 4));
}
export function activePodcastChapter<T extends { startSeconds: number }>(
  chapters: readonly T[] | undefined, position: number,
): T | undefined {
  if (!Number.isFinite(position)) return undefined;
  return (chapters ?? []).reduce<T | undefined>((active, chapter) =>
    Number.isFinite(chapter.startSeconds) && chapter.startSeconds >= 0 &&
    chapter.startSeconds <= position && (!active || chapter.startSeconds > active.startSeconds)
      ? chapter : active, undefined);
}

export function orderedPodcastChapters<T extends { startSeconds: number }>(
  chapters: readonly T[] | undefined, duration = Number.POSITIVE_INFINITY,
): T[] {
  return (chapters ?? []).filter((chapter) => Number.isFinite(chapter.startSeconds) &&
    chapter.startSeconds >= 0 && chapter.startSeconds <= duration)
    .sort((a, b) => a.startSeconds - b.startSeconds);
}

export const PODCAST_SILENCE_ANALYSIS_VERSION = "v2";
export function isCurrentSilenceAnalysis(analysis: { analysisVersion?: string } | null | undefined): boolean {
  return analysis?.analysisVersion === PODCAST_SILENCE_ANALYSIS_VERSION;
}
