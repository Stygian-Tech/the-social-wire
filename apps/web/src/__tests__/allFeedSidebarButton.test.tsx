import { afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";

import { AllFeedSidebarButton } from "@/components/AppSidebar/AllFeedSidebarButton";
import { SidebarProvider } from "@/components/ui/sidebar";

describe("AllFeedSidebarButton", () => {
  beforeAll(() => {
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({
        matches: false,
        addEventListener: () => undefined,
        removeEventListener: () => undefined,
      }),
    });
  });

  afterEach(cleanup);

  it("labels and selects the aggregate feed row", () => {
    const onSelect = mock(() => undefined);
    const { container, rerender } = render(
      <SidebarProvider>
        <AllFeedSidebarButton
          feed="following"
          isActive
          onSelect={onSelect}
        />
      </SidebarProvider>,
    );

    const followingButton = screen.getByRole("button", {
      name: "All Following",
    });
    const feedMenu = container.querySelector('[data-sidebar="menu"]');
    expect(feedMenu?.className).toContain("mb-2");
    expect(feedMenu?.className).toContain("pb-2");
    expect(followingButton.getAttribute("aria-current")).toBe("page");
    fireEvent.click(followingButton);
    expect(onSelect).toHaveBeenCalledWith("following");

    rerender(
      <SidebarProvider>
        <AllFeedSidebarButton
          feed="readLater"
          isActive={false}
          onSelect={onSelect}
        />
      </SidebarProvider>,
    );

    expect(
      screen
        .getByRole("button", { name: "All Read Later" })
        .getAttribute("aria-current"),
    ).toBeNull();
  });
});
