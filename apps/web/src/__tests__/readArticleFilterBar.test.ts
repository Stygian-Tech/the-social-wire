import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { createElement } from "react";
import { cleanup, render, screen } from "@testing-library/react";

import { readFeedHeaderClassName } from "@/app/read/ReadArticleFilterBar";
import { FeedHeader } from "@/components/FeedHeader/FeedHeader";
import { SidebarProvider } from "@/components/ui/sidebar";

beforeEach(() => {
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

describe("readFeedHeaderClassName", () => {
  it("adds breathing room only to The Wire header", () => {
    expect(readFeedHeaderClassName(true)).toBe("pt-3");
    expect(readFeedHeaderClassName(false)).toBeUndefined();
  });

  it("renders the simplified Wire header without subtitle or status copy", () => {
    const { container } = render(
      createElement(
        SidebarProvider,
        null,
        FeedHeader({
          title: "The Wire",
          className: readFeedHeaderClassName(true),
        }),
      ),
    );

    expect(screen.getByRole("heading", { name: "The Wire" })).toBeDefined();
    expect(container.querySelector("header p")).toBeNull();
    expect(screen.queryByText("Important stories across the social web")).toBeNull();
    expect(screen.queryByText("Showing fallback results")).toBeNull();
    expect(screen.queryByText(/moderation settings/i)).toBeNull();
  });
});
