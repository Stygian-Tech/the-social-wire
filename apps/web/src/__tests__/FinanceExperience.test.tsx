import { afterEach, beforeAll, beforeEach, describe, expect, it, mock, spyOn } from "bun:test";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import FinanceExperience from "@/components/FinanceExperience";
import * as FinanceHooks from "@/hooks/useFinanceFeed";
import * as PreferenceHooks from "@/hooks/useFeedDisplayPreferences";
import * as Customize from "@/components/FinanceCustomize";
import * as CardActions from "@/components/EntryList/EntryCardActionMenu";
import * as RowActions from "@/components/EntryList/EntryRowActions";
import * as Ticker from "@/components/FinanceTickerMarquee";
import { DEFAULT_FEED_DISPLAY_PREFERENCES } from "@/lib/feedPreferences";
import { OUTBOUND_WINDOW_FEATURES } from "@/lib/outboundLinks";

const publisherURL = "https://publisher.example/business/earnings";
const restores: (() => void)[] = [];
let openPublisher: ReturnType<typeof spyOn<typeof window, "open">>;

beforeAll(() => {
  for (const name of ["HTMLElement", "Element", "Node", "DOMRect"] as const) {
    Object.defineProperty(globalThis, name, { configurable: true, value: window[name] });
  }
  Object.defineProperty(globalThis, "getComputedStyle", { configurable: true, value: window.getComputedStyle.bind(window) });
  Object.defineProperty(globalThis, "requestAnimationFrame", { configurable: true, value: (callback: FrameRequestCallback) => setTimeout(callback, 0) });
  Object.defineProperty(globalThis, "cancelAnimationFrame", { configurable: true, value: (handle: number) => clearTimeout(handle) });
});

describe("Finance article navigation", () => {
  beforeEach(() => {
    const finance = {
      signedIn: false,
      items: [{
        story: {
          itemId: "finance-story",
          representativeUri: "at://did:plc:publisher/site.standard.document/story",
          canonicalUrl: publisherURL,
          title: "Company Reports Quarterly Earnings",
          publishedAt: "2026-10-02T10:00:00Z",
          source: { name: "Publisher", domain: "publisher.example" },
          reasons: [],
          provenance: [],
        },
        instruments: [],
        sectorIDs: [],
        majorGlobal: false,
      }],
      selections: [],
      feed: { data: { pages: [{ generatedAt: "2026-10-02T10:00:00Z" }] }, hasNextPage: false },
      isLoading: false,
      refreshing: false,
      suspended: false,
      error: null,
      saving: false,
      refresh: async () => {},
      saveSelection: async () => {},
    } as unknown as ReturnType<typeof FinanceHooks.useFinanceFeed>;
    const feed = spyOn(FinanceHooks, "useFinanceFeed").mockReturnValue(finance);
    const preferences = spyOn(PreferenceHooks, "useFeedDisplayPreferences").mockReturnValue({
      preferences: DEFAULT_FEED_DISPLAY_PREFERENCES,
      setHideFinancePerformance: () => {},
    } as unknown as ReturnType<typeof PreferenceHooks.useFeedDisplayPreferences>);
    const customize = spyOn(Customize, "FinanceCustomize").mockImplementation(() => <></>);
    const cardActions = spyOn(CardActions, "EntryCardActionMenu").mockImplementation(() => <></>);
    const rowActions = spyOn(RowActions, "EntryRowActions").mockImplementation(() => <></>);
    openPublisher = spyOn(window, "open").mockReturnValue(null);
    restores.push(...[feed, preferences, customize, cardActions, rowActions, openPublisher].map(spy => () => spy.mockRestore()));
  });

  afterEach(() => {
    cleanup();
    restores.splice(0).reverse().forEach(restore => restore());
  });

  it("opens the canonical publisher article immediately when its card is clicked", () => {
    render(<FinanceExperience />);
    fireEvent.click(screen.getByRole("heading", { name: "Company Reports Quarterly Earnings" }));
    expect(openPublisher).toHaveBeenCalledTimes(1);
    expect(openPublisher).toHaveBeenCalledWith(publisherURL, "_blank", OUTBOUND_WINDOW_FEATURES);
    expect(screen.queryByRole("dialog")).toBeNull();
    expect(screen.getAllByRole("heading", { name: "Company Reports Quarterly Earnings" })).toHaveLength(1);
  });

  it("passes performance visibility to the ticker and hides it immediately from Finance Options", async () => {
    const ticker = spyOn(Ticker, "FinanceTickerMarquee").mockImplementation(({ hidden }) => hidden ? null : <p>Visible Ticker</p>);
    restores.push(() => ticker.mockRestore());
    render(<FinanceExperience />);
    expect(screen.getByText("Visible Ticker")).not.toBeNull();
    expect(screen.queryByRole("menuitemcheckbox", { name: "Hide Performance Data" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Finance Options" }));
    const performance = await screen.findByRole("menuitemcheckbox", { name: "Hide Performance Data" });
    expect(performance.getAttribute("aria-checked")).toBe("false");
    fireEvent.click(performance);
    expect(screen.queryByText("Visible Ticker")).toBeNull();
  });

  it("refreshes feed choices and articles together from Finance Options", async () => {
    const finance = FinanceHooks.useFinanceFeed();
    const refresh = mock(async () => {});
    const refetch = mock(async () => {});
    spyOn(FinanceHooks, "useFinanceFeed").mockReturnValue({ ...finance, refresh, catalog: { refetch } } as unknown as ReturnType<typeof FinanceHooks.useFinanceFeed>);
    render(<FinanceExperience />);
    expect(screen.queryByRole("button", { name: "Refresh" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Finance Options" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Refresh" }));
    expect(refresh).toHaveBeenCalledTimes(1);
    expect(refetch).toHaveBeenCalledTimes(1);
  });

  it("keeps refresh disabled while a new edition is loading", async () => {
    const finance = FinanceHooks.useFinanceFeed();
    const refresh = mock(async () => {});
    spyOn(FinanceHooks, "useFinanceFeed").mockReturnValue({ ...finance, refresh, refreshing: true });
    render(<FinanceExperience />);
    fireEvent.click(screen.getByRole("button", { name: "Finance Options" }));
    const item = await screen.findByRole("menuitem", { name: "Refresh" });
    expect(item.getAttribute("aria-disabled")).toBe("true");
    fireEvent.click(item);
    expect(refresh).not.toHaveBeenCalled();
  });

  it("opens customization from Finance Options while keeping feed search available", async () => {
    spyOn(Customize, "FinanceCustomize").mockImplementation(({ open }) => open ? <div role="dialog" aria-label="Customize Finance" /> : <></>);
    render(<FinanceExperience />);
    expect(screen.getByRole("combobox", { name: "Finance Feed" })).toBeTruthy();
    expect(screen.getByRole("searchbox", { name: "Find a Company" })).toBeTruthy();
    expect(screen.queryByRole("button", { name: "Customize" })).toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Finance Options" }));
    fireEvent.click(await screen.findByRole("menuitem", { name: "Customize" }));
    expect(screen.getByRole("dialog", { name: "Customize Finance" })).toBeTruthy();
  });

  it("does not show global ticker symbols while a named feed is unresolved", () => {
    const ticker = spyOn(Ticker, "FinanceTickerMarquee").mockImplementation(() => <p>Visible Ticker</p>);
    restores.push(() => ticker.mockRestore());
    render(<FinanceExperience feedID="instrument:unknown" />);
    expect(screen.queryByText("Visible Ticker")).toBeNull();
  });

  for (const key of ["Enter", " "]) {
    it(`opens the publisher directly on ${key === " " ? "Space" : key} activation`, () => {
      render(<FinanceExperience />);
      fireEvent.keyDown(screen.getByRole("link", { name: /Company Reports Quarterly Earnings/ }), { key });
      expect(openPublisher).toHaveBeenCalledTimes(1);
      expect(openPublisher).toHaveBeenCalledWith(publisherURL, "_blank", OUTBOUND_WINDOW_FEATURES);
      expect(screen.queryByRole("dialog")).toBeNull();
    });
  }

  it("does not open an article for navigation keys", () => {
    render(<FinanceExperience />);
    fireEvent.keyDown(screen.getByRole("link", { name: /Company Reports Quarterly Earnings/ }), { key: "ArrowDown" });
    expect(openPublisher).not.toHaveBeenCalled();
  });
  it("uses the server catalog for grouped choices and keeps named feeds empty", async () => {
    const finance = FinanceHooks.useFinanceFeed();
    spyOn(FinanceHooks, "useFinanceFeed").mockReturnValue({...finance, items: [], catalog: {data: {feeds: [
      {id:"finance",title:"Finance",kind:"all",description:"Broad market coverage",instrumentIDs:[],sectorIDs:[]},
      {id:"industry:pharma",title:"Pharma",kind:"industry",description:"Pharmaceutical industry reporting",instrumentIDs:[],sectorIDs:["healthcare"]},
      {id:"group:mag7",title:"Mag7",kind:"group",description:"Seven leading companies",instrumentIDs:["apple"],sectorIDs:[]},
      {id:"instrument:apple",title:"Apple · AAPL · NASDAQ",kind:"instrument",description:"Apple reporting",instrumentIDs:["apple"],sectorIDs:[]},
    ]}}} as unknown as ReturnType<typeof FinanceHooks.useFinanceFeed>);
    const changed: string[] = [];
    render(<FinanceExperience feedID="industry:pharma" onFeedChange={id=>changed.push(id)} />);
    expect(screen.getByRole("heading",{name:"Pharma"})).toBeTruthy();
    fireEvent.click(screen.getByRole("combobox", {name:"Finance Feed"}));
    await screen.findByRole("option", {name:"Pharma"});
    expect(screen.getByRole("group",{name:"Industries"})).toBeTruthy();
    expect(screen.getByRole("group",{name:"Groups"})).toBeTruthy();
    expect(screen.getByRole("option",{name:"Apple · AAPL · NASDAQ"})).toBeTruthy();
    expect(screen.getByText(/No matching stories/)).toBeTruthy();
    expect(screen.queryByText("No finance stories are available right now.")).toBeNull();
    await userEvent.click(screen.getByRole("option", {name:"Mag7"}));
    expect(changed).toEqual(["group:mag7"]);
    fireEvent.change(screen.getByRole("searchbox",{name:"Find a Company"}),{target:{value:"NASDAQ"}});
    fireEvent.click(screen.getByRole("combobox", {name:"Finance Feed"}));
    expect(await screen.findByRole("option",{name:"Apple · AAPL · NASDAQ"})).toBeTruthy();
    fireEvent.keyDown(screen.getByRole("listbox"), { key: "Escape" });
    fireEvent.change(screen.getByRole("searchbox",{name:"Find a Company"}),{target:{value:"unknown"}});
    fireEvent.click(screen.getByRole("combobox", {name:"Finance Feed"}));
    await screen.findByRole("option", {name:"Mag7"});
    expect(screen.queryByRole("option",{name:"Apple · AAPL · NASDAQ"})).toBeNull();
    expect(screen.getByText("No companies match your search.")).toBeTruthy();
    expect(screen.getByRole("option",{name:"Mag7"})).toBeTruthy();
  });

  it("shares the algorithmic feed layout while preserving server order and publisher navigation", () => {
    const finance = FinanceHooks.useFinanceFeed();
    const items = ["Lead Story", "Supporting Story", "Third Story", "Fourth Story", "More Coverage", "Sixth Story"].map((title, index) => ({
      ...finance.items[0],
      story: {...finance.items[0].story, itemId: `story-${index}`, representativeUri: `${finance.items[0].story.representativeUri}-${index}`, title, canonicalUrl: `${publisherURL}/${index}`},
    }));
    spyOn(FinanceHooks, "useFinanceFeed").mockReturnValue({...finance, items});
    const { container } = render(<FinanceExperience />);
    expect(screen.getByRole("heading", {name: "Top Stories"})).toBeTruthy();
    expect(screen.getByRole("heading", {name: "More Stories"})).toBeTruthy();
    const topStories = screen.getByRole("region", {name: "Top Stories"});
    const moreStories = screen.getByRole("group", {name: "More Stories carousel"});
    const storyIDs = (element: Element) => [...element.querySelectorAll("[data-wire-story-id]")].map(row => row.getAttribute("data-wire-story-id"));
    expect(storyIDs(topStories)).toEqual(["story-0", "story-1", "story-2", "story-3"]);
    expect(storyIDs(moreStories)).toEqual(["story-4", "story-5"]);
    expect(storyIDs(container)).toEqual(items.map(item => item.story.itemId));
    items.forEach((item, index) => {
      expect(screen.getAllByRole("heading", {name: item.story.title})).toHaveLength(1);
      const heading = screen.getByRole("heading", {name: item.story.title});
      fireEvent.click(heading);
      expect(openPublisher).toHaveBeenNthCalledWith(index + 1, item.story.canonicalUrl, "_blank", OUTBOUND_WINDOW_FEATURES);
    });
  });

});
