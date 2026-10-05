import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { PodcastSeekBar } from "@/components/Podcasts/PodcastSeekBar";

afterEach(cleanup);

describe("Compact podcast seek bar", () => {
  it("bounds progress and exposes a native range for keyboard and pointer seeking", () => {
    const seek = mock(() => {});
    const view = render(<PodcastSeekBar position={150} duration={100} seek={seek} label="Seek Episode" />);
    const slider = screen.getByRole("slider", { name: "Seek Episode" }) as HTMLInputElement;
    expect(slider.value).toBe("100");
    expect(slider.min).toBe("0");
    expect(slider.max).toBe("100");
    expect(slider.step).toBe("0.1");
    expect((view.container.querySelector(".bg-primary") as HTMLElement).style.width).toBe("100%");
    fireEvent.change(slider, { target: { value: "49.9" } });
    expect(seek).toHaveBeenCalledWith(49.9);
    view.rerender(<PodcastSeekBar position={-10} duration={100} seek={seek} />);
    expect((screen.getByRole("slider") as HTMLInputElement).value).toBe("0");
  });

  it.each([0, -1, Number.NaN, Number.POSITIVE_INFINITY])("disables unknown or invalid duration %s with an empty playhead", duration => {
    const seek = mock(() => {});
    const view = render(<PodcastSeekBar position={20} duration={duration} seek={seek} />);
    const slider = screen.getByRole("slider") as HTMLInputElement;
    expect(slider.disabled).toBe(true);
    expect(slider.value).toBe("0");
    expect(slider.max).toBe("0");
    expect((view.container.querySelector(".bg-primary") as HTMLElement).style.width).toBe("0%");
    fireEvent.change(slider, { target: { value: "10" } });
    expect(seek).not.toHaveBeenCalled();
  });
});
