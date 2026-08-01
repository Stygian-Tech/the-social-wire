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

    fireEvent.click(screen.getByRole("button", { name: "Following" }));
    expect(onSelect).toHaveBeenCalledWith("following");
  });
});
