import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  mock,
  spyOn,
} from "bun:test";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";

import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import * as AuthHook from "@/hooks/useAuth";
import * as WireEditionHook from "@/hooks/useWireEdition";
import type { EntryListItem } from "@/lib/atprotoClient";
import * as ResolveEntryOpenURL from "@/lib/resolveEntryOpenUrl";
import { READ_STATE_STORAGE_KEY } from "@/lib/entryReadStateStorage";
import type { WireEditionPage } from "@/lib/wireEditionClient";

beforeAll(() => {
  Object.defineProperty(globalThis, "Element", {
    configurable: true,
    value: window.Element,
  });
  Object.defineProperty(globalThis, "HTMLElement", {
    configurable: true,
    value: window.HTMLElement,
  });
});

let restoreAuthSpy: (() => void) | undefined;
let resolveEntryOpenUrlFromPds: ReturnType<
  typeof spyOn<typeof ResolveEntryOpenURL, "resolveEntryOpenUrlFromPds">
>;
let useWireEdition: ReturnType<
  typeof spyOn<typeof WireEditionHook, "useWireEdition">
>;

beforeEach(() => {
  process.env.NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED = "true";
  window.localStorage.clear();
  renderedEntry = unresolvedEntry;
  renderedEntryListProps = {};
  const authSpy = spyOn(AuthHook, "useAuth").mockReturnValue({
    session: { did: "did:plc:viewer" },
    getOAuthSession: () => null,
  } as ReturnType<typeof AuthHook.useAuth>);
  restoreAuthSpy = () => authSpy.mockRestore();
  resolveEntryOpenUrlFromPds = spyOn(
    ResolveEntryOpenURL,
    "resolveEntryOpenUrlFromPds",
  ).mockResolvedValue(undefined);
  useWireEdition = spyOn(
    WireEditionHook,
    "useWireEdition",
  ).mockImplementation(
    () =>
      ({
        data: {
          pages: [wireEditionPageForEntry(renderedEntry)],
          pageParams: [undefined],
        },
        catalog: { isLoading: false },
        isLoading: false,
        isError: false,
        error: null,
        viewerModerationError: false,
        moreStories: [],
        hasNextPage: false,
        isFetchingNextPage: false,
        isFetchNextPageError: false,
        fetchNextPage: async () => undefined,
        retryTheWire: async () => undefined,
      }) as unknown as ReturnType<typeof WireEditionHook.useWireEdition>,
  );
});

afterEach(() => {
  delete process.env.NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED;
  cleanup();
  window.localStorage.clear();
  restoreAuthSpy?.();
  restoreAuthSpy = undefined;
  resolveEntryOpenUrlFromPds.mockRestore();
  useWireEdition.mockRestore();
});

/** standard.site entry the AppView could not index a hosted URL for. */
const unresolvedEntry: EntryListItem = {
  entryId: "at://did:plc:alice/site.standard.document/entry-1",
  title: "Standard Site Article",
  publishedAt: "2026-01-01T00:00:00.000Z",
};
let renderedEntry = unresolvedEntry;
let renderedEntryListProps: {
  wireFeed?: boolean;
  readIndicatorsEnabled?: boolean;
  articleFilter?: string;
} = {};

function wireEditionPageForEntry(entry: EntryListItem): WireEditionPage {
  const itemId = entry.wireItem?.itemId ?? entry.entryId;
  return {
    editionVersion: "1",
    generationId: "test-generation",
    generatedAt: "2026-08-20T12:00:00.000Z",
    language: "en",
    source: "ranked",
    degraded: false,
    stories: [
      {
        itemId,
        canonicalUrl: entry.originalUrl ?? "https://news.example/story",
        representativeUri: entry.entryId,
        title: entry.title,
        publishedAt: entry.publishedAt,
        source: entry.wireItem?.source ?? {
          name: "Example News",
          domain: "news.example",
        },
        reasons: entry.wireItem?.reasons ?? [],
        provenance: entry.wireItem?.provenance ?? [],
      },
    ],
    topStoryIds: [itemId],
    publicationSpotlights: [],
    storyRails: [],
    people: [],
    trendingStoryIds: [],
  };
}

mock.module("@/components/EntryList/EntryList", () => ({
  EntryList: ({
    onSelectEntry,
    resolvingEntryId,
    wireFeed,
    readIndicatorsEnabled,
    articleFilter,
  }: {
    onSelectEntry: (entryId: string, entry?: EntryListItem) => void;
    resolvingEntryId?: string | null;
    wireFeed?: boolean;
    readIndicatorsEnabled?: boolean;
    articleFilter?: string;
  }) => (
    <button
      type="button"
      data-testid="entry-row"
      aria-busy={resolvingEntryId === renderedEntry.entryId || undefined}
      onClick={() => onSelectEntry(renderedEntry.entryId, renderedEntry)}
      ref={() => {
        renderedEntryListProps = {
          wireFeed,
          readIndicatorsEnabled,
          articleFilter,
        };
      }}
    >
      {renderedEntry.title}
    </button>
  ),
}));

const { default: ReadPubPage } = await import(
  "@/app/read/[...pubId]/ReadPubPage"
);

function Wrapper({ children }: { children: ReactNode }) {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  return (
    <QueryClientProvider client={queryClient}>
      <ReadRouteProvider>{children}</ReadRouteProvider>
    </QueryClientProvider>
  );
}

function renderPage() {
  return render(
    <ReadPubPage pubId="at://did:plc:alice/site.standard.publication/main" />,
    { wrapper: Wrapper },
  );
}

type OpenedTab = { closed: boolean; location: { href: string } };

function stubWindowOpen(): { tabs: OpenedTab[]; restore: () => void } {
  const original = window.open;
  const tabs: OpenedTab[] = [];
  window.open = ((_url?: string | URL, _target?: string, features?: string) => {
    const tab: OpenedTab = { closed: false, location: { href: "" } };
    tabs.push(tab);
    // Browsers return null when the features string asks for noopener/noreferrer, so a caller
    // that needs the handle to navigate the tab later must not pass them.
    if (features && /\bno(opener|referrer)\b/.test(features)) return null;
    return {
      close: () => {
        tab.closed = true;
      },
      location: tab.location,
      opener: window as Window | null,
    } as unknown as Window;
  }) as typeof window.open;
  return {
    tabs,
    restore: () => {
      window.open = original;
    },
  };
}

describe("ReadPubPage entry open fallback", () => {
  it("opens the PDS-resolved URL when the AppView has no destination", async () => {
    resolveEntryOpenUrlFromPds.mockResolvedValue(
      "https://example.com/posts/hello",
    );
    const { tabs, restore } = stubWindowOpen();

    try {
      renderPage();
      act(() => screen.getByTestId("entry-row").click());

      await waitFor(() => {
        expect(tabs[0]?.location.href).toBe("https://example.com/posts/hello");
      });
      // The tab is claimed synchronously so Safari does not treat it as a popup.
      expect(tabs).toHaveLength(1);
      expect(tabs[0]?.closed).toBe(false);
      expect(screen.queryByRole("status")).toBeNull();
    } finally {
      restore();
    }
  });

  it("opens The Wire stories through the isolated news surface without creating read state", async () => {
    renderedEntry = {
      entryId: "at://did:plc:writer/site.standard.document/wire-story",
      title: "The Wire Story",
      publishedAt: "2026-08-20T12:00:00.000Z",
      originalUrl: "https://news.example/story",
      wireItem: {
        itemId: "wire:item:one",
        representativeUri:
          "at://did:plc:writer/site.standard.document/wire-story",
        source: { name: "Example News", domain: "news.example" },
        reasons: ["breaking_story"],
        provenance: [],
      },
    };
    const { tabs, restore } = stubWindowOpen();

    try {
      render(
        <ReadPubPage wireFeed />,
        { wrapper: Wrapper },
      );
      const storyTitle = await screen.findByText("The Wire Story");
      const story = storyTitle.closest('[role="link"]');
      if (!story) throw new Error("Wire story card did not render");
      act(() => (story as HTMLElement).click());

      expect(renderedEntryListProps).toEqual({});
      expect(tabs).toHaveLength(1);
      expect(window.localStorage.getItem(READ_STATE_STORAGE_KEY)).toBeNull();
      expect(resolveEntryOpenUrlFromPds).not.toHaveBeenCalled();
    } finally {
      restore();
      renderedEntry = unresolvedEntry;
    }
  });

  it("keeps the existing Wire list active until the news edition rollout gate is enabled", () => {
    delete process.env.NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED;

    render(<ReadPubPage wireFeed />, { wrapper: Wrapper });

    expect(screen.getByTestId("entry-row")).toBeDefined();
    expect(renderedEntryListProps).toEqual({
      wireFeed: true,
      readIndicatorsEnabled: false,
      articleFilter: "all",
    });
  });

  it("surfaces a message instead of silently doing nothing", async () => {
    resolveEntryOpenUrlFromPds.mockResolvedValue(undefined);
    const { tabs, restore } = stubWindowOpen();

    try {
      renderPage();
      act(() => screen.getByTestId("entry-row").click());

      const status = await screen.findByRole("status");
      expect(status.textContent).toContain(
        "Couldn't Find A Link For This Article.",
      );
      expect(tabs[0]?.closed).toBe(true);
    } finally {
      restore();
    }
  });

  it("marks the row busy while the destination is resolving", async () => {
    let release: (url: string | undefined) => void = () => {};
    resolveEntryOpenUrlFromPds.mockImplementation(
      () =>
        new Promise<string | undefined>((resolve) => {
          release = resolve;
        }),
    );
    const { restore } = stubWindowOpen();

    try {
      renderPage();
      act(() => screen.getByTestId("entry-row").click());

      await waitFor(() => {
        expect(screen.getByTestId("entry-row").getAttribute("aria-busy")).toBe(
          "true",
        );
      });

      await act(async () => release("https://example.com/posts/hello"));
      await waitFor(() => {
        expect(
          screen.getByTestId("entry-row").getAttribute("aria-busy"),
        ).toBeNull();
      });
    } finally {
      restore();
      resolveEntryOpenUrlFromPds.mockReset();
    }
  });
});
