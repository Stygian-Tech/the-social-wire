import { afterEach, beforeAll, describe, expect, it, mock } from "bun:test";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";

import type { WireEditionPage } from "@/lib/wireEditionClient";

mock.module("@/components/EntryList/EntryCardActionMenu", () => ({
  EntryCardActionMenu: () => <button type="button" aria-label="Story Actions" />,
}));
beforeAll(() => {
  Object.defineProperty(globalThis, "Element", {
    configurable: true,
    value: window.Element,
  });
  Object.defineProperty(globalThis, "HTMLElement", {
    configurable: true,
    value: window.HTMLElement,
  });
  Object.defineProperty(globalThis, "Node", {
    configurable: true,
    value: window.Node,
  });
  Object.defineProperty(globalThis, "getComputedStyle", {
    configurable: true,
    value: window.getComputedStyle.bind(window),
  });
  Object.defineProperty(globalThis, "requestAnimationFrame", {
    configurable: true,
    value: (callback: FrameRequestCallback) => setTimeout(callback, 0),
  });
  Object.defineProperty(globalThis, "cancelAnimationFrame", {
    configurable: true,
    value: (handle: number) => clearTimeout(handle),
  });
});

afterEach(() => {
  cleanup();
  delete document.documentElement.dataset.font;
  delete document.documentElement.dataset.boldText;
});

const page: WireEditionPage = {
  editionVersion: "1",
  generationId: "generation-1",
  generatedAt: "2026-08-21T12:00:00.000Z",
  language: "en",
  source: "ranked",
  degraded: false,
  stories: [
    {
      itemId: "lead",
      canonicalUrl: "https://news.example/lead",
      title: "The Lead Story",
      summary: "The most important development right now.",
      publishedAt: "2026-08-21T11:00:00.000Z",
      source: {
        name: "Example News",
        domain: "news.example",
        publication: "at://did:plc:news/site.standard.publication/main",
        homepageUrl: "https://news.example",
        iconUrl: "https://news.example/icon.png",
      },
      reasons: ["breaking_story"],
      provenance: ["standard_site"],
    },
    {
      itemId: "analysis",
      canonicalUrl: "https://analysis.example/story",
      title: "A Deeper Analysis",
      summary: "Supporting summary should not render in the compact top slot.",
      publishedAt: "2026-08-21T09:30:00.000Z",
      thumbnailUrl: "https://analysis.example/thumbnail.jpg",
      source: {
        name: "Analysis Daily",
        domain: "analysis.example",
        author: "Riley Reporter",
        homepageUrl: "https://analysis.example",
        iconUrl: "https://analysis.example/icon.png",
      },
      reasons: ["widely_discussed"],
      provenance: ["direct_share"],
    },
    {
      itemId: "more",
      canonicalUrl: "https://more.example/story",
      title: "One More Story",
      source: { name: "More News", domain: "more.example" },
      reasons: [],
      provenance: [],
    },
    {
      itemId: "extra",
      canonicalUrl: "https://extra.example/story",
      title: "An Additional Story",
      source: { name: "Extra News", domain: "extra.example" },
      reasons: [],
      provenance: [],
    },
    {
      itemId: "remainder",
      canonicalUrl: "https://remainder.example/story",
      title: "A Remaining Story",
      source: { name: "Remainder News", domain: "remainder.example" },
      reasons: [],
      provenance: [],
    },
  ],
  topStoryIds: ["lead", "analysis", "more", "extra"],
  publicationSpotlights: [
    {
      id: "example-news",
      publication: {
        name: "news.example",
        domain: "news.example",
        publication: "at://did:plc:news/site.standard.publication/main",
      },
      storyIds: ["lead", "analysis"],
    },
  ],
  storyRails: [
    { id: "widely-discussed", title: "Widely Discussed", storyIds: ["analysis"] },
  ],
  people: [
    {
      did: "did:plc:person",
      handle: "person.example",
      displayName: "Important Person",
      description: "At the center of several stories.",
    },
  ],
  trendingStoryIds: ["analysis"],
};

describe("WireNewsEditionLayout", () => {
  it("renders the editorial modules and keeps publication identity ahead of titles", async () => {
    const { WireNewsEditionLayout } = await import(
      "@/components/Wire/WireNewsEditionLayout"
    );
    const { container } = render(
      <WireNewsEditionLayout
        pages={[page]}
        continuedStories={[]}
        hasNextPage={false}
        isFetchingNextPage={false}
        isLoadMoreError={false}
        onLoadMore={async () => undefined}
        onSelect={() => undefined}
      />,
    );

    expect(screen.getByRole("heading", { name: "Top Stories" })).toBeDefined();
    expect(
      screen.getByRole("heading", { name: "Publication Spotlights" }),
    ).toBeDefined();
    expect(
      screen.getByRole("heading", { name: "People in the Story" }),
    ).toBeDefined();
    expect(
      screen.getByRole("heading", { name: "Trending Stories" }),
    ).toBeDefined();
    const trending = screen
      .getByRole("heading", { name: "Trending Stories" })
      .closest("aside");
    expect(trending?.getAttribute("tabindex")).toBe("0");
    expect(trending?.className).toContain("xl:overflow-y-auto");
    expect(trending?.className).toContain("xl:[scrollbar-gutter:stable]");
    expect(
      trending?.querySelector("[data-wire-trending-list]")?.className,
    ).toContain("divide-y");
    const trendingStory = trending?.querySelector(
      '[data-wire-story-id="analysis"]',
    );
    expect(trendingStory?.className).toContain(
      "grid-cols-[minmax(0,1fr)_7rem]",
    );
    expect(trendingStory?.className).toContain("rounded-none");
    expect(trendingStory?.className).toContain("shadow-none");
    expect(trendingStory?.textContent).toContain("Analysis Daily");
    expect(trendingStory?.textContent).toContain("A Deeper Analysis");
    expect(trendingStory?.textContent).toContain("Aug 21");
    expect(trendingStory?.textContent).not.toContain("By Riley Reporter");
    expect(trendingStory?.textContent).not.toContain("analysis.example");
    expect(trendingStory?.textContent).not.toContain("Widely Discussed");
    expect(trendingStory?.querySelector("img")?.getAttribute("src")).toBe(
      "https://analysis.example/thumbnail.jpg",
    );
    expect(
      trendingStory?.querySelector("[data-wire-trending-actions]")?.className,
    ).toContain("[@media(hover:hover)]:opacity-0");
    expect(
      trendingStory?.querySelector("[data-wire-trending-actions]")?.className,
    ).toContain("group-focus-within/story:opacity-100");
    expect(screen.getByRole("heading", { name: "Widely Discussed" })).toBeDefined();
    expect(screen.getByRole("heading", { name: "More Stories" })).toBeDefined();
    expect(screen.getByText("Important Person")).toBeDefined();
    expect(
      screen.queryByText("at://did:plc:news/site.standard.publication/main"),
    ).toBeNull();
    expect(
      screen.getByRole("group", { name: "Publication Spotlights carousel" }),
    ).toBeDefined();
    expect(
      screen.getByRole("group", { name: "Publication Spotlights carousel" }).className,
    ).toContain("scroll-pl-5");
    expect(
      screen.getByRole("group", { name: "Publication Spotlights carousel" }).className,
    ).toContain("pt-2");
    const publicationSpotlight = container.querySelector(
      '[data-wire-publication-spotlight="example-news"]',
    );
    const publicationSpotlightHeader = publicationSpotlight?.firstElementChild;
    expect(publicationSpotlightHeader?.textContent).toContain("Example News");
    expect(publicationSpotlightHeader?.textContent).toContain("news.example");
    expect(
      publicationSpotlightHeader?.querySelector("a")?.getAttribute("href"),
    ).toBe("https://news.example");
    expect(
      publicationSpotlightHeader?.querySelector("img")?.getAttribute("src"),
    ).toBe("https://news.example/icon.png");

    const lead = container.querySelector('[data-wire-story-id="lead"]');
    const leadText = lead?.textContent ?? "";
    expect(leadText.indexOf("Example News")).toBeLessThan(
      leadText.indexOf("The Lead Story"),
    );
    expect(container.firstElementChild?.getAttribute("data-wire-generation")).toBe(
      "generation-1",
    );
    const topStoriesGrid = container.querySelector(
      "[data-wire-top-stories-grid]",
    );
    expect(topStoriesGrid?.className).toContain(
      "lg:grid-cols-[minmax(0,1.15fr)_minmax(21rem,1fr)]",
    );
    expect(
      topStoriesGrid?.querySelectorAll("[data-wire-story-id]").length,
    ).toBe(4);
    const supportingStory = topStoriesGrid?.querySelector(
      '[data-wire-story-id="analysis"]',
    );
    expect(supportingStory?.className).toContain(
      "lg:grid-cols-[minmax(0,1fr)_9rem]",
    );
    expect(supportingStory?.textContent).not.toContain(
      "Supporting summary should not render in the compact top slot.",
    );
    expect(
      supportingStory?.querySelector(".lg\\:whitespace-normal")?.textContent,
    ).toBe("Analysis Daily");

    fireEvent.focus(trendingStory as Element);
    await waitFor(() => {
      const metadata = document.querySelector(
        "[data-wire-story-hover-metadata]",
      );
      expect(metadata?.textContent).toContain("A Deeper Analysis");
      expect(metadata?.textContent).toContain("Riley Reporter");
      expect(metadata?.textContent).toContain("analysis.example");
      expect(metadata?.textContent).toContain("Published");
      expect(metadata?.className).toContain("bg-popover");
      expect(metadata?.className).toContain("text-popover-foreground");
    });

    const scrollContainer = container.querySelector(
      "[data-wire-scroll-container]",
    );
    expect(scrollContainer?.className).toContain("overflow-y-auto");
    expect(scrollContainer?.firstElementChild?.className).toContain(
      "max-w-[calc(var(--reader-shell-width)-var(--sidebar-width))]",
    );
  });

  it("keeps an authoritative spotlight name while filling missing artwork from its stories", async () => {
    const { effectiveSpotlightPublication } = await import(
      "@/components/Wire/WirePublicationSpotlights"
    );
    const resolved = effectiveSpotlightPublication(
      {
        id: "authoritative",
        publication: {
          name: "The Authoritative Daily",
          domain: "authoritative.example",
        },
        storyIds: ["story"],
      },
      [
        {
          entryId: "story",
          title: "Story",
          publishedAt: "2026-08-21T12:00:00.000Z",
          wireItem: {
            itemId: "story",
            source: {
              name: "A Later Child Name",
              domain: "authoritative.example",
              homepageUrl: "https://authoritative.example",
              iconUrl: "https://authoritative.example/icon.png",
            },
            reasons: [],
            provenance: [],
          },
        },
      ],
    );

    expect(resolved).toEqual({
      name: "The Authoritative Daily",
      domain: "authoritative.example",
      homepageUrl: "https://authoritative.example",
      iconUrl: "https://authoritative.example/icon.png",
    });
  });

  it("provides keyboard-focusable carousel controls with reduced-motion-aware scrolling", async () => {
    const { WireHorizontalRail } = await import(
      "@/components/Wire/WireHorizontalRail"
    );
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: () => ({ matches: false }),
    });
    render(
      <WireHorizontalRail id="test" title="Test Stories">
        <span>One</span>
        <span>Two</span>
      </WireHorizontalRail>,
    );
    const rail = screen.getByRole("group", { name: "Test Stories carousel" });
    expect(rail.className).toContain("scroll-pl-5");
    expect(rail.className).toContain("sm:scroll-pl-6");
    expect(rail.className).toContain("pt-2");
    Object.defineProperty(rail, "clientWidth", { configurable: true, value: 300 });
    Object.defineProperty(rail, "scrollWidth", { configurable: true, value: 900 });
    Object.defineProperty(rail, "scrollLeft", {
      configurable: true,
      value: 0,
      writable: true,
    });
    const scrollBy = mock(() => undefined);
    Object.defineProperty(rail, "scrollBy", {
      configurable: true,
      value: scrollBy,
    });

    fireEvent.scroll(rail);
    const previous = screen.getByRole("button", { name: "Previous Test Stories" });
    const next = screen.getByRole("button", { name: "Next Test Stories" });
    expect(previous.hasAttribute("disabled")).toBe(true);
    expect(next.hasAttribute("disabled")).toBe(false);

    fireEvent.click(next);
    expect(scrollBy).toHaveBeenCalledWith({ left: 255, behavior: "smooth" });
  });

  it("inherits the selected app font and bold-text preferences without a Wire override", async () => {
    document.documentElement.dataset.font = "serif";
    document.documentElement.dataset.boldText = "true";
    const { WireNewsEditionLayout } = await import(
      "@/components/Wire/WireNewsEditionLayout"
    );
    const { container } = render(
      <WireNewsEditionLayout
        pages={[page]}
        continuedStories={[]}
        hasNextPage={false}
        isFetchingNextPage={false}
        isLoadMoreError={false}
        onLoadMore={async () => undefined}
        onSelect={() => undefined}
      />,
    );

    expect(document.documentElement.dataset.font).toBe("serif");
    expect(document.documentElement.dataset.boldText).toBe("true");
    expect(container.querySelector(".font-serif")).toBeNull();
    expect(container.querySelector("[style*='font-family']")).toBeNull();
  });
});
