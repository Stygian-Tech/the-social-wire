import { afterEach, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { Play } from "lucide-react";
import { PodcastEpisodeActionButton } from "@/components/Podcasts/PodcastEpisodeActionButton";

afterEach(cleanup);

it("keeps the action name accessible and the compact icon decorative", () => {
  render(<PodcastEpisodeActionButton icon={Play} aria-describedby="action-help">Play Episode</PodcastEpisodeActionButton>);
  const button = screen.getByRole("button", { name: "Play Episode" });
  expect(button.getAttribute("type")).toBe("button");
  expect(button.getAttribute("aria-describedby")).toBe("action-help");
  expect(button.querySelector("svg")?.getAttribute("aria-hidden")).toBe("true");
  expect(screen.queryByRole("img")).toBeNull();
  expect(button.classList.contains("min-h-8")).toBe(true);
  expect(button.classList.contains("text-xs")).toBe(true);
  expect(button.className).toContain("pointer-coarse:min-h-11");
  expect(button.querySelector("svg")?.classList.contains("size-3.5")).toBe(true);
});

it("forwards callbacks and disabled state without submitting a surrounding form", () => {
  const clicked = mock(() => {});
  const submitted = mock(() => {});
  const view = render(<form onSubmit={submitted}><PodcastEpisodeActionButton icon={Play} onClick={clicked} className="fixture-marker">Play</PodcastEpisodeActionButton></form>);
  fireEvent.click(screen.getByRole("button", { name: "Play" }));
  expect(clicked).toHaveBeenCalledTimes(1);
  expect(submitted).not.toHaveBeenCalled();
  expect(screen.getByRole("button").classList.contains("fixture-marker")).toBe(true);
  view.rerender(<form onSubmit={submitted}><PodcastEpisodeActionButton icon={Play} onClick={clicked} disabled>Play</PodcastEpisodeActionButton></form>);
  fireEvent.click(screen.getByRole("button", { name: "Play" }));
  expect(clicked).toHaveBeenCalledTimes(1);
  expect((screen.getByRole("button") as HTMLButtonElement).disabled).toBe(true);
});
