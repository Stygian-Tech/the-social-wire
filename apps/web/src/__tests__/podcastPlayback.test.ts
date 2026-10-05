import { describe, expect, it } from "bun:test";
import {
  clampPlaybackTime,
  formatPodcastTime,
  PODCAST_SPEEDS,
  silenceSkipTarget,
  activeTranscriptCue,
  validateClipBounds,
} from "@/lib/podcasts/playback";
import { mergePodcastPatch } from "@/lib/podcasts/state";
import { initialPodcastState } from "@/lib/podcasts/client";
describe("Podcast playback timeline", () => {
  it("offers every supported speed and clamps forward/back seeks", () => {
    expect(PODCAST_SPEEDS).toEqual([
      0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3,
    ]);
    expect(clampPlaybackTime(-15, 300)).toBe(0);
    expect(clampPlaybackTime(330, 300)).toBe(300);
    expect(clampPlaybackTime(NaN, 300)).toBe(0);
    expect(formatPodcastTime(3661)).toBe("1:01:01");
  });
  it("skips only analyzed silence interiors and keeps source-time cue alignment", () => {
    const silences = [
      { start: 5, end: 9 },
      { start: NaN, end: 20 },
    ];
    expect(silenceSkipTarget(4.9, silences, 60)).toBeNull();
    expect(silenceSkipTarget(6, silences, 60)).toBe(9);
    expect(silenceSkipTarget(9, silences, 60)).toBeNull();
    expect(
      activeTranscriptCue([{ start: 9, end: 12, text: "After pause" }], 9),
    ).toBe(0);
  });
  it("requires finite in-episode clip bounds and caps expensive processing", () => {
    expect(validateClipBounds(0, 600, 3600)).toBe(true);
    expect(validateClipBounds(0, 601, 3600)).toBe(false);
    expect(validateClipBounds(20, 20, 30)).toBe(false);
    expect(validateClipBounds(20, 31, 30)).toBe(false);
    expect(validateClipBounds(NaN, 20, 30)).toBe(false);
  });
});
describe("Podcast private state synchronization", () => {
  it("preserves server queue/preferences when replaying a local progress edit", () => {
    const server = {
      ...initialPodcastState(),
      queue: ["remote"],
      playbackSpeed: 2,
      progress: {
        episode: {
          positionSeconds: 100,
          updatedAt: "2026-10-05T01:00:00Z",
          completed: false,
        },
      },
    };
    const merged = mergePodcastPatch(server, {
      progress: {
        another: {
          positionSeconds: 5,
          updatedAt: "2026-10-05T01:01:00Z",
          completed: false,
        },
      },
    });
    expect(merged.queue).toEqual(["remote"]);
    expect(merged.playbackSpeed).toBe(2);
    expect(merged.progress.episode.positionSeconds).toBe(100);
  });
  it("rejects stale offline progress but accepts a newer intentional backward seek", () => {
    const server = {
      ...initialPodcastState(),
      progress: {
        episode: {
          positionSeconds: 100,
          updatedAt: "2026-10-05T01:00:00Z",
          completed: false,
        },
      },
    };
    const stale = mergePodcastPatch(server, {
      progress: {
        episode: {
          positionSeconds: 20,
          updatedAt: "2026-10-05T00:59:00Z",
          completed: false,
        },
      },
    });
    expect(stale.progress.episode.positionSeconds).toBe(100);
    const seek = mergePodcastPatch(server, {
      progress: {
        episode: {
          positionSeconds: 20,
          updatedAt: "2026-10-05T01:01:00Z",
          completed: false,
        },
      },
    });
    expect(seek.progress.episode.positionSeconds).toBe(20);
  });
});
