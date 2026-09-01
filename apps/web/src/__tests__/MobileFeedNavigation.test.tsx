import { afterEach, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

import { MobileFeedNavigation } from "@/components/AppSidebar/MobileFeedNavigation";

afterEach(cleanup);

describe("MobileFeedNavigation", () => {
  it("shows visible feeds and preserves the active feed", () => {
    const onSelect = mock(() => undefined);
    render(
      <MobileFeedNavigation
        currentFeed="subscribed"
        visibleFeeds={new Set(["readLater", "subscribed", "following"])}
        onSelect={onSelect}
      />,
    );

    expect(screen.queryByRole("button", { name: "Archive" })).toBeNull();
    expect(
      screen.getByRole("button", { name: "Subscribed" }).getAttribute("aria-current"),
    ).toBe("page");
    expect(
      screen
        .getByRole("button", { name: "Subscribed" })
        .querySelector("svg")
        ?.classList.contains("lucide-newspaper"),
    ).toBe(true);

    fireEvent.click(screen.getByRole("button", { name: "Following" }));
    expect(onSelect).toHaveBeenCalledWith("following");
  });

  it("shows The Wire only when runtime capabilities include it", () => {
    const onSelect = mock(() => undefined);
    const { rerender } = render(
      <MobileFeedNavigation
        currentFeed="wire"
        visibleFeeds={new Set(["wire", "subscribed"])}
        onSelect={onSelect}
      />,
    );

    const wire = screen.getByRole("button", { name: "The Wire, Beta" });
    expect(screen.getByText("Beta")).toBeDefined();
    expect(wire.querySelector("svg")?.classList.contains("lucide-rss")).toBe(true);
    expect(wire.getAttribute("aria-current")).toBe("page");
    fireEvent.click(wire);
    expect(onSelect).toHaveBeenCalledWith("wire");

    rerender(
      <MobileFeedNavigation
        currentFeed="subscribed"
        visibleFeeds={new Set(["subscribed"])}
        onSelect={onSelect}
      />,
    );
    expect(screen.queryByRole("button", { name: "The Wire, Beta" })).toBeNull();
  });

  it("shows Your Circle only when the authenticated catalog enables it", () => {
    const onSelect = mock(() => undefined);
    render(
      <MobileFeedNavigation
        currentFeed="circle"
        visibleFeeds={new Set(["circle", "subscribed"])}
        onSelect={onSelect}
      />,
    );

    const circle = screen.getByRole("button", { name: "Your Circle, Beta" });
    expect(screen.getByText("Beta")).toBeDefined();
    expect(circle.querySelector("svg")?.classList.contains("lucide-network")).toBe(
      true,
    );
    expect(circle.getAttribute("aria-current")).toBe("page");
    fireEvent.click(circle);
    expect(onSelect).toHaveBeenCalledWith("circle");
  });
});
