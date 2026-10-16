import {
  afterEach,
  beforeAll,
  beforeEach,
  describe,
  expect,
  it,
  spyOn,
} from "bun:test";
import { act, cleanup, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { ReactNode } from "react";

import * as DisplayPreferences from "@/hooks/useFeedDisplayPreferences";
import { DEFAULT_FEED_DISPLAY_PREFERENCES } from "@/lib/feedPreferences";
import * as Runtime from "@/lib/pdsReadStateRuntime";
import * as PendingRead from "@/hooks/usePendingPDSReadState";
import * as SyncNotice from "@/components/Account/PDSReadStateSyncNotice";
import * as Thin from "@/lib/thinAppViewClient";
import * as RssReader from "@/components/EntryDetail/RssArticleReaderDialog";
import { ARTICLE_LIST_FILTER_STORAGE_KEY } from "@/lib/articleListFilterStorage";
import { ReadRouteProvider } from "@/contexts/ReadRouteContext";
import * as AuthHook from "@/hooks/useAuth";
import * as EntryListModule from "@/components/EntryList/EntryList";
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
let restoreEntryListSpy: (() => void) | undefined;
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
  const entryListSpy = spyOn(EntryListModule, "EntryList").mockImplementation(renderEntryList);
  restoreEntryListSpy = () => entryListSpy.mockRestore();
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
  restoreEntryListSpy?.();
  restoreEntryListSpy = undefined;
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

const renderEntryList = ({
    onSelectEntry,
    markEntryUnread,
    resolvingEntryId,
    wireFeed,
    readIndicatorsEnabled,
    articleFilter,
  }: {
    onSelectEntry: (entryId: string, entry?: EntryListItem) => void;
    markEntryUnread: (entryId: string) => void;
    resolvingEntryId?: string | null;
    wireFeed?: boolean;
    readIndicatorsEnabled?: boolean;
    articleFilter?: string;
  }) => (
    <>
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
    <button data-testid="mark-unread" onClick={() => markEntryUnread(renderedEntry.entryId)}>Mark As Unread</button>
    </>
  );

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

function mutationHarness() {
  let oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
  const getOAuthSession = () => oauth;
  const read = spyOn(Thin, "writeThroughReadMark").mockResolvedValue();
  const unread = spyOn(Thin, "writeThroughReadMarkDelete").mockResolvedValue();
  const spies = [
    spyOn(AuthHook, "useAuth").mockImplementation(() => ({ session: { did: oauth.did }, getOAuthSession } as ReturnType<typeof AuthHook.useAuth>)),
    spyOn(DisplayPreferences, "useFeedDisplayPreferences").mockReturnValue({ preferences: { ...DEFAULT_FEED_DISPLAY_PREFERENCES, rssArticleOpenMode: "reader" } } as ReturnType<typeof DisplayPreferences.useFeedDisplayPreferences>),
    spyOn(Runtime, "pdsReadStateEnabled").mockReturnValue(false),
    spyOn(Runtime, "usesPDSReadState").mockResolvedValue(false),
    spyOn(PendingRead, "usePendingPDSReadState").mockReturnValue(new Map()),
    spyOn(SyncNotice, "PDSReadStateSyncNotice").mockReturnValue(null),
    spyOn(Thin, "isThinAppViewEnabled").mockReturnValue(true),
    spyOn(RssReader, "RssArticleReaderDialog").mockImplementation(({ open, onClose }) => <>{open ? <button data-testid="close-reader" onClick={onClose}>Close Reader</button> : null}</>),
    read, unread,
  ];
  return { read, unread, restore() { spies.forEach(spy => spy.mockRestore()); }, switchAccount() { oauth = { did: "did:plc:other" } as unknown as OAuthSession; } };
}
function persistedRead(entryId: string) { return JSON.parse(window.localStorage.getItem(READ_STATE_STORAGE_KEY) ?? "{}")[entryId]; }
it("does not replay an old async article-open read over a newer explicit unread", async () => {
  const mutations = mutationHarness(); const tabs = stubWindowOpen();
  let finish!: (url: string) => void;
  resolveEntryOpenUrlFromPds.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  try {
    renderedEntry = { ...unresolvedEntry, isRead: true };
    const page = renderPage(); await act(async () => {});
    act(() => screen.getByTestId("entry-row").click());
    act(() => screen.getByTestId("mark-unread").click());
    await waitFor(() => expect(mutations.unread).toHaveBeenCalledTimes(1));
    await act(async () => finish("https://example.com/resolved"));
    expect(tabs.tabs[0].location.href).toBe("https://example.com/resolved");
    expect(mutations.read).not.toHaveBeenCalled();
    expect(persistedRead(unresolvedEntry.entryId)).toBeUndefined();
    page.unmount(); renderPage(); await act(async () => {});
    expect(persistedRead(unresolvedEntry.entryId)).toBeUndefined();
  } finally { tabs.restore(); mutations.restore(); }
});
it("discards an old account's unresolved article-open completion", async () => {
  const mutations = mutationHarness(); const tabs = stubWindowOpen(); let finish!: (url: string) => void;
  resolveEntryOpenUrlFromPds.mockImplementation(() => new Promise(resolve => { finish = resolve; }));
  try {
    const page = renderPage(); await act(async () => {});
    act(() => screen.getByTestId("entry-row").click());
    act(() => { mutations.switchAccount(); page.rerender(<ReadPubPage pubId="at://did:plc:alice/site.standard.publication/main" />); });
    await act(async () => finish("https://example.com/resolved"));
    expect(mutations.read).not.toHaveBeenCalled(); expect(tabs.tabs[0].closed).toBe(true);
  } finally { tabs.restore(); mutations.restore(); }
});
for (const explicitUnread of [false, true]) {
  it(`RSS deferred close ${explicitUnread ? "preserves a newer explicit unread" : "still marks an untouched article read"}`, async () => {
    const mutations = mutationHarness();
    renderedEntry = { ...unresolvedEntry, entryId: "rssentry:article", originalUrl: "https://example.com/rss" };
    window.localStorage.setItem(ARTICLE_LIST_FILTER_STORAGE_KEY, "unread");
    try {
      renderPage(); await act(async () => {});
      act(() => screen.getByTestId("entry-row").click());
      expect(mutations.read).not.toHaveBeenCalled();
      if (explicitUnread) {
        act(() => screen.getByTestId("mark-unread").click());
        await waitFor(() => expect(mutations.unread).toHaveBeenCalledTimes(1));
      }
      act(() => screen.getByTestId("close-reader").click()); await act(async () => {});
      expect(mutations.read.mock.calls.length).toBe(explicitUnread ? 0 : 1);
    } finally { mutations.restore(); }
  });
}

for (const explicitUnread of [false, true]) {
  it(`switching RSS articles ${explicitUnread ? "preserves the previous article's newer unread" : "still marks the previous article read"}`, async () => {
    const mutations = mutationHarness();
    const firstId = "rssentry:first"; const secondId = "rssentry:second";
    renderedEntry = { ...unresolvedEntry, entryId: firstId, originalUrl: "https://example.com/first" };
    window.localStorage.setItem(ARTICLE_LIST_FILTER_STORAGE_KEY, "unread");
    try {
      renderPage(); await act(async () => {});
      act(() => screen.getByTestId("entry-row").click());
      if (explicitUnread) {
        act(() => screen.getByTestId("mark-unread").click());
        await waitFor(() => expect(mutations.unread).toHaveBeenCalledTimes(1));
      }
      renderedEntry = { ...renderedEntry, entryId: secondId, originalUrl: "https://example.com/second" };
      act(() => screen.getByTestId("entry-row").click()); await act(async () => {});
      expect(mutations.read.mock.calls.map(([, id]) => id)).toEqual(explicitUnread ? [] : [firstId]);
      act(() => screen.getByTestId("close-reader").click()); await act(async () => {});
      expect(mutations.read.mock.calls.map(([, id]) => id)).toEqual(explicitUnread ? [secondId] : [firstId, secondId]);
    } finally { mutations.restore(); }
  });
}
