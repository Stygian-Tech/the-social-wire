import { afterEach, expect, it } from "bun:test";
import { cleanup, render, screen } from "@testing-library/react";
import { PodcastEpisodeProgress } from "@/components/Podcasts/PodcastEpisodeProgress";

afterEach(cleanup);
it("shows elapsed and remaining time and updates live progress", () => {
  const view = render(<PodcastEpisodeProgress position={35} duration={120} />);
  expect(screen.getByText("0:35 / 2:00")).toBeTruthy();
  expect(screen.getByText("1:25 Left")).toBeTruthy();
  expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("29");
  view.rerender(<PodcastEpisodeProgress position={65} duration={120} />);
  expect(screen.getByText("1:05 / 2:00")).toBeTruthy();
  expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("54");
});
it("avoids a fabricated percentage for unknown durations and hides untouched episodes", () => {
  const view = render(<PodcastEpisodeProgress position={35} />);
  expect(screen.getByText("0:35 Listened")).toBeTruthy();
  expect(screen.queryByRole("progressbar")).toBeNull();
  view.rerender(<PodcastEpisodeProgress position={NaN} duration={120} />);
  expect(screen.queryByLabelText("Episode Playback Progress")).toBeNull();
});
it("clamps stale positions and keeps completed episodes complete", () => {
  const view = render(<PodcastEpisodeProgress position={180} duration={120} />);
  expect(screen.getByText("2:00 / 2:00")).toBeTruthy();
  expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("100");
  view.rerender(<PodcastEpisodeProgress position={35} duration={120} completed />);
  expect(screen.getByRole("progressbar").getAttribute("aria-valuenow")).toBe("100");
  expect(screen.queryByText("1:25 Left")).toBeNull();
});
