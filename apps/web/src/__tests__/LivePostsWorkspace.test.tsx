import { afterEach, beforeEach, expect, mock, spyOn, test } from "bun:test";
import type { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Atproto from "@/lib/atprotoClient";
import { listViewerAtmoEvents } from "@/lib/livePosts/atmoEventClient";
import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import * as Auth from "@/hooks/useAuth";
import * as Live from "@/hooks/useLivePosts";
import * as Mobile from "@/hooks/use-mobile";
import { SidebarProvider } from "@/components/ui/sidebar";
import LivePostPage from "@/app/live-post/page";
import { LivePostNewEventDialog } from "@/components/LivePosts/LivePostNewEventDialog";
import { localLiveTimeZone } from "@/lib/livePosts/livePostTimestamp";
import type { LiveEvent } from "@/lib/livePosts/livePostTypes";

const event: LiveEvent = { $type: "app.thesocialwire.liveEvent", uri: "at://did:plc:alice/app.thesocialwire.liveEvent/event", cid: "cid", title: "Launch", tags: ["Launch"], destination: "both", createdAt: "2026-10-11T12:00:00Z", updatedAt: "2026-10-11T12:00:00Z", articleUrl: "https://blog.test/live", entries: [{ id: "u", text: "Published Earlier", createdAt: "2026-10-11T12:00:00Z", articleRef: { uri: "at://did:plc:alice/site.standard.document/article", cid: "article" }, postRef: { uri: "at://did:plc:alice/app.bsky.feed.post/post", cid: "post" } }] };
const restores: (() => void)[] = [];
let client: QueryClient;
let state: ReturnType<typeof Live.useLivePosts>;
beforeEach(() => {
  const mobile = spyOn(Mobile, "useIsMobile").mockReturnValue(false);
  restores.push(() => mobile.mockRestore());
  client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: Infinity } } });
  for (const [name, value] of Object.entries({ getComputedStyle: window.getComputedStyle.bind(window), HTMLElement: window.HTMLElement, HTMLInputElement: window.HTMLInputElement, Element: window.Element, Node: window.Node, MutationObserver: window.MutationObserver, requestAnimationFrame: (callback: FrameRequestCallback) => setTimeout(() => callback(performance.now()), 0), cancelAnimationFrame: clearTimeout })) {
    const previous = Object.getOwnPropertyDescriptor(globalThis, name);
    Object.defineProperty(globalThis, name, { configurable: true, value });
    restores.push(() => { if (previous) Object.defineProperty(globalThis, name, previous); else Reflect.deleteProperty(globalThis, name); });
  }
  const auth = spyOn(Auth, "useAuth").mockReturnValue({ session: { did: "did:plc:alice" } } as ReturnType<typeof Auth.useAuth>);
  restores.push(() => auth.mockRestore());
  state = { events: [event], rsvpEvents: [], rsvpLoading: false, rsvpError: null, loading: false, error: null, pending: false, publications: [], publicationsLoading: false, publicationsError: null, refresh: mock(async () => {}), createEvent: mock(async () => event), publishUpdate: mock(async () => event), updateTimestampSettings: mock(async () => event), endEvent: mock(async () => ({ ...event, endedAt: new Date().toISOString() })) };
  const live = spyOn(Live, "useLivePosts").mockImplementation(() => state);
  restores.push(() => live.mockRestore());
});
afterEach(() => { cleanup(); client.clear(); restores.splice(0).reverse().forEach(restore => restore()); });
async function mount() { await act(async () => { render(<QueryClientProvider client={client}><SidebarProvider><LivePostPage /></SidebarProvider></QueryClientProvider>); }); }
function selectEvent(title = "Launch") { fireEvent.click(within(screen.getByRole("complementary", { name: "Live Events" })).getByRole("button", { name: new RegExp(title) })); }

test("renders an empty schedule with a create action when there are no events", async () => {
  state.events = [];
  await mount();
  const schedule = within(screen.getByRole("region", { name: "Live Post Schedule" }));
  expect(schedule.getByRole("heading", { name: /^Current$/ })).toBeTruthy();
  expect(schedule.getByRole("heading", { name: /^Upcoming$/ })).toBeTruthy();
  expect(screen.queryByRole("form", { name: "Live Update Composer" })).toBeNull();
  fireEvent.click(schedule.getByRole("button", { name: "New Event" }));
  expect(screen.getByRole("dialog")).toBeTruthy();
  expect(state.createEvent).not.toHaveBeenCalled();
});

test("opens the schedule without selecting an ended session and keeps history in Your Events", async () => {
  state.events = [{ ...event, endedAt: "2026-10-26T23:00:00Z" }];
  await mount();
  const schedule = within(screen.getByRole("region", { name: "Live Post Schedule" }));
  expect(schedule.getByRole("heading", { name: "Live Post Schedule" })).toBeTruthy();
  expect(schedule.getByRole("heading", { name: /^Current$/ })).toBeTruthy();
  expect(schedule.getByRole("heading", { name: /^Upcoming$/ })).toBeTruthy();
  expect(schedule.queryByText("Launch")).toBeNull();
  expect(screen.queryByText("Published Earlier")).toBeNull();
  expect(screen.queryByRole("form", { name: "Live Update Composer" })).toBeNull();
  expect(within(screen.getByRole("complementary", { name: "Live Events" })).getByRole("button", { name: /Launch.*Ended/ })).toBeTruthy();
});

test("shows current and upcoming events in the schedule while leaving past events in the sidebar", async () => {
  state.events = [event, { ...event, uri: `${event.uri}-past`, title: "Ended Session", endedAt: "2000-01-01T17:00:00Z" }];
  state.rsvpEvents = [
    { uri: "at://did:plc:alice/community.lexicon.calendar.event/future", cid: "future", title: "Future Conference", startsAt: "2100-01-01T09:00:00Z", endsAt: "2100-01-01T17:00:00Z", url: "https://atmo.rsvp/e/future" },
    { uri: "at://did:plc:alice/community.lexicon.calendar.event/past", cid: "past", title: "Past Conference", startsAt: "2000-01-01T09:00:00Z", endsAt: "2000-01-01T17:00:00Z", url: "https://atmo.rsvp/e/past" },
  ];
  await mount();
  const schedule = within(screen.getByRole("region", { name: "Live Post Schedule" }));
  expect(schedule.getByRole("button", { name: /Launch/ })).toBeTruthy();
  expect(schedule.getByRole("button", { name: /Future Conference/ })).toBeTruthy();
  expect(schedule.queryByText("Ended Session")).toBeNull();
  expect(schedule.queryByText("Past Conference")).toBeNull();
  const sidebar = within(screen.getByRole("complementary", { name: "Live Events" }));
  expect(sidebar.getByRole("button", { name: /Ended Session/ })).toBeTruthy();
  expect(sidebar.getByRole("button", { name: /Past Conference/ })).toBeTruthy();
  fireEvent.click(schedule.getByRole("button", { name: /Launch/ }));
  expect(screen.getByRole("textbox", { name: "Update" })).toBeTruthy();
  expect(screen.queryByRole("region", { name: "Live Post Schedule" })).toBeNull();
});

test("orders upcoming owned and RSVP events by their scheduled start", async () => {
  state.events = [{ ...event, title: "Late Session", startsAt: "2100-01-03T09:00:00Z", endsAt: "2100-01-03T17:00:00Z" }];
  state.rsvpEvents = [
    { uri: "at://did:plc:alice/community.lexicon.calendar.event/middle", cid: "middle", title: "Middle Conference", startsAt: "2100-01-02T09:00:00Z", endsAt: "2100-01-02T17:00:00Z", url: "https://atmo.rsvp/e/middle" },
    { uri: "at://did:plc:alice/community.lexicon.calendar.event/first", cid: "first", title: "First Conference", startsAt: "2100-01-01T09:00:00Z", endsAt: "2100-01-01T17:00:00Z", url: "https://atmo.rsvp/e/first" },
  ];
  await mount();
  const upcoming = within(screen.getByRole("region", { name: "Upcoming Schedule" }));
  const buttons = upcoming.getAllByRole("button");
  expect(buttons[0].textContent).toContain("First Conference");
  expect(buttons[1].textContent).toContain("Middle Conference");
  expect(buttons[2].textContent).toContain("Late Session");
  expect(buttons).toHaveLength(3);
  expect(buttons[0].querySelector("time")?.getAttribute("datetime")).toBe("2100-01-01T09:00:00Z");
});

test("waits for event discovery before showing the empty schedule action", async () => {
  state.events = [];
  state.rsvpLoading = true;
  await mount();
  const schedule = within(screen.getByRole("region", { name: "Live Post Schedule" }));
  expect(schedule.getByRole("status").textContent).toBe("Loading Schedule…");
  expect(schedule.queryByText("No Live Events Scheduled")).toBeNull();
  expect(schedule.queryByRole("button", { name: "New Event" })).toBeNull();
  state.rsvpLoading = false;
  fireEvent.click(screen.getByRole("button", { name: "New Event" }));
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(schedule.queryByRole("status")).toBeNull();
  expect(schedule.getByRole("button", { name: "New Event" })).toBeTruthy();
});

test("View Schedule returns from the editor and preserves the event draft", async () => {
  await mount();
  selectEvent();
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "Keep This Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "View Schedule" }));
  expect(screen.getByRole("heading", { name: "Live Post Schedule" })).toBeTruthy();
  expect(screen.queryByRole("textbox", { name: "Update" })).toBeNull();
  selectEvent();
  expect((screen.getByRole("textbox", { name: "Update" }) as HTMLTextAreaElement).value).toBe("Keep This Draft");
  expect(state.publishUpdate).not.toHaveBeenCalled();
});

test("publishes explicitly, retains failed update for retry, and clears only after success", async () => {
  const publish = mock(async () => { throw new Error("Network Failed"); });
  state.publishUpdate = publish;
  await mount();
  selectEvent();
  const input = screen.getByRole("textbox", { name: "Update" });
  fireEvent.change(input, { target: { value: "New Update" } });
  expect(publish).toHaveBeenCalledTimes(0);
  fireEvent.click(screen.getByRole("button", { name: "Publish Update" }));
  await screen.findByRole("button", { name: "Retry Publish" });
  expect((input as HTMLTextAreaElement).value).toBe("New Update");
  expect(publish).toHaveBeenCalledWith(event.uri, "New Update", undefined);
  state.publishUpdate = mock(async () => event);
  fireEvent.click(screen.getByRole("button", { name: "Retry Publish" }));
  await waitFor(() => expect((input as HTMLTextAreaElement).value).toBe(""));
});

test("shows published destination links and validates Bluesky limits including event metadata", async () => {
  await mount();
  selectEvent();
  expect(screen.getByRole("link", { name: "View Bluesky Update" }).getAttribute("href")).toContain("/social/post?");
  expect(screen.getByRole("link", { name: "View Article" }).getAttribute("href")).toBe("https://blog.test/live");
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "x".repeat(300) } });
  expect((screen.getByRole("button", { name: "Publish Update" }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByText(/exceeds Bluesky/)).toBeDefined();
});

test("requires a publication for blog events and parses comma-separated hashtags", async () => {
  const create = mock(async () => {});
  await act(async () => { render(<LivePostNewEventDialog open onOpenChange={() => {}} publications={[{ uri: "at://did:plc:alice/site.standard.publication/p", cid: "p", name: "My Blog", url: "https://blog.test", host: "unknown", record: {} }]} publicationsLoading={false} pending={false} onCreate={create} />); });
  fireEvent.change(screen.getByRole("textbox", { name: "Event Title" }), { target: { value: "  New Launch  " } });
  fireEvent.change(screen.getByRole("textbox", { name: "Event Hashtags" }), { target: { value: "#Tech, Launch, Tech" } });
  fireEvent.click(screen.getByRole("radio", { name: "Both" }));
  expect((screen.getByRole("button", { name: "Create Event" }) as HTMLButtonElement).disabled).toBe(true);
  fireEvent.change(screen.getByRole("combobox", { name: "Event Publication" }), { target: { value: "at://did:plc:alice/site.standard.publication/p" } });
  fireEvent.click(screen.getByRole("button", { name: "Create Event" }));
  await waitFor(() => expect(create).toHaveBeenCalledWith({ timestampFormat: "time-24", timeZone: localLiveTimeZone(), title: "New Launch", tags: ["Tech", "Launch"], destination: "both", publicationUri: "at://did:plc:alice/site.standard.publication/p" }));
});

test("disables blog destinations without an eligible viewer publication", async () => {
  await act(async () => { render(<LivePostNewEventDialog open onOpenChange={() => {}} publications={[]} publicationsLoading={false} pending={false} onCreate={async () => {}} />); });
  expect((screen.getByRole("radio", { name: "Blog" }) as HTMLInputElement).disabled).toBe(true);
  expect((screen.getByRole("radio", { name: "Both" }) as HTMLInputElement).disabled).toBe(true);
});

test("keeps update drafts separate between events and disables publishing while pending", async () => {
  const other = { ...event, uri: `${event.uri}-other`, title: "Another Event", entries: [] };
  state.events = [event, other];
  await mount();
  selectEvent();
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "Launch Draft" } });
  selectEvent("Another Event");
  expect((screen.getByRole("textbox", { name: "Update" }) as HTMLTextAreaElement).value).toBe("");
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "Other Draft" } });
  selectEvent();
  expect((screen.getByRole("textbox", { name: "Update" }) as HTMLTextAreaElement).value).toBe("Launch Draft");
  state.pending = true;
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "Next Draft" } });
  expect((screen.getByRole("button", { name: "Publishing…" }) as HTMLButtonElement).disabled).toBe(true);
});

test("prepopulates an RSVP event without writing until the user creates its live event", async () => {
  state.rsvpEvents = [{ uri: "at://did:plc:alice/community.lexicon.calendar.event/rsvp", cid: "source", title: "Future Conference", startsAt: "2100-01-01T09:00:00+01:00", endsAt: "2100-01-01T17:00:00+01:00", url: "https://atmo.rsvp/e/source" }];
  await mount();
  fireEvent.click(within(screen.getByRole("region", { name: "Live Post Schedule" })).getByRole("button", { name: /Future Conference/ }));
  expect(state.createEvent).not.toHaveBeenCalled();
  expect((screen.getByRole("textbox", { name: "Event Title" }) as HTMLInputElement).value).toBe("Future Conference");
  expect(screen.getByRole("dialog").querySelector('time[datetime="2100-01-01T09:00:00+01:00"]')).not.toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Create Event" }));
  await waitFor(() => expect(state.createEvent).toHaveBeenCalledWith({ timestampFormat: "time-24", timeZone: localLiveTimeZone(), title: "Future Conference", tags: [], destination: "bluesky", publicationUri: undefined, sourceEvent: { uri: "at://did:plc:alice/community.lexicon.calendar.event/rsvp", cid: "source" }, startsAt: "2100-01-01T09:00:00+01:00", endsAt: "2100-01-01T17:00:00+01:00" }));
});

test("groups events by schedule, keeps undated owned events current, and avoids duplicate RSVP sources", async () => {
  const source = { uri: "at://did:plc:alice/community.lexicon.calendar.event/linked", cid: "linked" };
  state.events = [{ ...event, sourceEvent: source }];
  state.rsvpEvents = [
    { ...source, title: "Duplicate Source", url: "https://atmo.rsvp/e/linked" },
    { uri: "at://did:plc:alice/community.lexicon.calendar.event/past", cid: "past", title: "Past Conference", startsAt: "2000-01-01T09:00:00Z", endsAt: "2000-01-01T17:00:00Z", url: "https://atmo.rsvp/e/past" },
  ];
  await mount();
  expect(screen.queryByText("Duplicate Source")).toBeNull();
  const sidebar = within(screen.getByRole("complementary", { name: "Live Events" }));
  const current = sidebar.getByText("Current").closest("details");
  const past = sidebar.getByText("Past").closest("details");
  expect(current?.open).toBe(true);
  expect(current?.textContent).toContain("Launch");
  expect(past?.open).toBe(false);
  expect(past?.textContent).toContain("Past Conference");
});


test("refreshes scheduled event sections each minute and cleans up its clock", async () => {
  let now = Date.parse("2026-10-11T12:00:00Z");
  let tick: (() => void) | undefined;
  const clock = spyOn(Date, "now").mockImplementation(() => now);
  const interval = spyOn(window, "setInterval").mockImplementation(((callback: TimerHandler) => { tick = callback as () => void; return 42; }) as unknown as typeof window.setInterval);
  const clear = spyOn(window, "clearInterval");
  restores.push(() => clock.mockRestore(), () => interval.mockRestore(), () => clear.mockRestore());
  state.rsvpEvents = [{ uri: "at://did:plc:alice/community.lexicon.calendar.event/boundary", cid: "source", title: "Scheduled Event", startsAt: "2026-10-11T12:01:00Z", endsAt: "2026-10-11T12:03:00Z", url: "https://atmo.rsvp/e/boundary" }];
  await mount();
  const sidebar = within(screen.getByRole("complementary", { name: "Live Events" }));
  const upcoming = sidebar.getByText("Upcoming").closest("details")!;
  expect(upcoming.textContent).toContain("Scheduled Event");
  // Native details retains its user-controlled state during React renders.
  upcoming.open = false;
  now += 60_000;
  act(() => { tick?.(); });
  expect(sidebar.getByText("Current").closest("details")?.textContent).toContain("Scheduled Event");
  expect(upcoming.open).toBe(false);
  now += 120_000;
  act(() => { tick?.(); });
  expect(within(screen.getByRole("complementary", { name: "Live Events" })).getByText("Past").closest("details")?.textContent).toContain("Scheduled Event");
  cleanup();
  expect(clear).toHaveBeenCalledWith(42);
});


test("bounds long event navigation and event history in separate desktop scroll panes", async () => {
  state.events = Array.from({ length: 40 }, (_, index) => ({ ...event, uri: `${event.uri}-${index}`, title: `Event ${index}` }));
  await mount();
  const sidebar = screen.getByRole("complementary", { name: "Live Events" });
  const workspace = screen.getByRole("region", { name: "Live Event Workspace" });
  expect(sidebar.classList.contains("lg:overflow-y-auto")).toBe(true);
  expect(workspace.classList.contains("lg:overflow-y-auto")).toBe(true);
  const header = screen.getByRole("heading", { name: "Live Post", level: 1 }).closest("header")!;
  const shell = header.parentElement!;
  expect(shell.classList.contains("lg:grid-cols-[minmax(0,1fr)_18rem]")).toBe(true);
  expect(shell.classList.contains("lg:grid-rows-[auto_minmax(0,1fr)]")).toBe(true);
  expect(header.classList.contains("lg:col-start-1")).toBe(true);
  expect(workspace.classList.contains("lg:col-start-1")).toBe(true);
  expect(workspace.classList.contains("lg:row-start-2")).toBe(true);
  expect(sidebar.classList.contains("lg:row-span-2")).toBe(true);
  // One shared header keeps the same adjacent mobile scroll pane and overlay.
  expect(header.nextElementSibling?.contains(sidebar)).toBe(true);
  expect(header.nextElementSibling?.contains(workspace)).toBe(true);
  expect(sidebar.compareDocumentPosition(workspace) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(screen.getAllByRole("heading", { name: "Live Post", level: 1 })).toHaveLength(1);
  selectEvent("Event 39");
  expect(screen.getByRole("heading", { name: "Event 39" })).toBeTruthy();
});

test("existing events expose editable format/timezone with preview and explicit save", async () => {
  await mount();
  selectEvent();
  fireEvent.change(screen.getByRole("combobox", { name: "Timestamp Format", hidden: true }), { target: { value: "time-12" } });
  fireEvent.change(screen.getByRole("textbox", { name: "Time Zone", hidden: true }), { target: { value: "America/Chicago" } });
  expect(screen.getByLabelText("Timestamp Preview").textContent).toMatch(/\d{2}:\d{2} [AP]M/);
  expect(state.updateTimestampSettings).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Save Timestamp Settings", hidden: true }));
  await waitFor(() => expect(state.updateTimestampSettings).toHaveBeenCalledWith(event, { timestampFormat: "time-12", timeZone: "America/Chicago" }));
  expect(state.publishUpdate).not.toHaveBeenCalled();
});

test("confirms ending a session, warns about unpublished drafts, and preserves published history", async () => {
  const ended = { ...event, endedAt: "2026-10-26T23:00:00Z" };
  state.endEvent = mock(async () => { state.events = [ended]; return ended; });
  await mount();
  selectEvent();
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "Unpublished Draft" } });
  fireEvent.click(screen.getByRole("button", { name: "End Live Post" }));
  expect(state.endEvent).not.toHaveBeenCalled();
  expect(screen.getByText(/You have an unpublished draft/)).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(state.endEvent).not.toHaveBeenCalled();
  expect((screen.getByRole("textbox", { name: "Update" }) as HTMLTextAreaElement).value).toBe("Unpublished Draft");
  fireEvent.click(screen.getByRole("button", { name: "End Live Post" }));
  fireEvent.click(screen.getByRole("button", { name: "Confirm End Live Post" }));
  await screen.findByRole("heading", { name: "Live Post Schedule" });
  expect(state.endEvent).toHaveBeenCalledWith(event.uri);
  expect(screen.queryByRole("form", { name: "Live Update Composer" })).toBeNull();
  expect(screen.queryByRole("button", { name: "End Live Post" })).toBeNull();
  expect(screen.queryByText("Published Earlier")).toBeNull();
  expect(within(screen.getByRole("complementary", { name: "Live Events" })).getByText("Past").closest("details")?.textContent).toContain("Launch");
  selectEvent();
  expect(screen.getByText(/Live Post Ended/)).toBeTruthy();
  expect(screen.getByText("Published Earlier")).toBeTruthy();
});

test("failed session ending retains the draft and allows an explicit retry", async () => {
  const end = mock(async () => { throw new Error("Connection Lost"); });
  state.endEvent = end;
  await mount();
  selectEvent();
  fireEvent.change(screen.getByRole("textbox", { name: "Update" }), { target: { value: "Keep Me" } });
  fireEvent.click(screen.getByRole("button", { name: "End Live Post" }));
  fireEvent.click(screen.getByRole("button", { name: "Confirm End Live Post" }));
  await screen.findByText("Connection Lost");
  expect((screen.getByLabelText("Update") as HTMLTextAreaElement).value).toBe("Keep Me");
  expect(screen.getByRole("button", { name: "Confirm End Live Post" })).toBeTruthy();
  expect(end).toHaveBeenCalledTimes(1);
});

test("a persisted ended event is read-only after reopening", async () => {
  state.events = [{ ...event, endedAt: "2026-10-26T23:00:00Z" }];
  await mount();
  selectEvent();
  expect(screen.queryByRole("textbox", { name: "Update" })).toBeNull();
  expect(screen.queryByRole("button", { name: "Publish Update" })).toBeNull();
  expect(screen.queryByRole("button", { name: "End Live Post" })).toBeNull();
  expect(screen.getByRole("link", { name: "View Bluesky Update" })).toBeTruthy();
});


test("passes GIF attachments to publishing, retains failed media drafts, and renders saved media", async () => {
  const gif = { url: "https://media.test/countdown.gif", alt: "Countdown" };
  const publish = mock(async () => { throw new Error("Offline"); });
  state.publishUpdate = publish;
  await mount();
  selectEvent();
  fireEvent.click(screen.getByRole("button", { name: "Add GIF" }));
  fireEvent.change(screen.getByRole("textbox", { name: "GIF URL" }), { target: { value: gif.url } });
  fireEvent.change(screen.getByRole("textbox", { name: "GIF Alt Text" }), { target: { value: gif.alt } });
  fireEvent.click(screen.getByRole("button", { name: "Publish Update" }));
  await screen.findByRole("button", { name: "Retry Publish" });
  expect(publish).toHaveBeenCalledWith(event.uri, "", { gif });
  expect((screen.getByRole("textbox", { name: "GIF URL" }) as HTMLInputElement).value).toBe(gif.url);
  state.publishUpdate = mock(async () => {
    const updated = { ...event, entries: [...event.entries, { id: "gif", text: "", createdAt: "2026-10-26T23:00:00Z", media: { gif } }] };
    state.events = [updated];
    return updated;
  });
  fireEvent.click(screen.getByRole("button", { name: "Retry Publish" }));
  await waitFor(() => expect(screen.queryByRole("textbox", { name: "GIF URL" })).toBeNull());
  expect(screen.getByRole("img", { name: "Countdown" }).getAttribute("src")).toBe(gif.url);
});


test("renders ended live sessions and genuine discovered events without legacy article mirrors", async () => {
  const collection = "community.lexicon.calendar.event", did = "did:plc:alice";
  const cid = "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku";
  const article = { uri: `at://${did}/${collection}/article`, cid, value: { $type: collection, name: "First Offprint Test", createdAt: "2026-08-12T17:51:07Z", startsAt: "2026-08-12T17:51:07Z", mode: `${collection}#virtual`, status: `${collection}#scheduled`, uris: [{ name: "Article URL", uri: "https://blog.test/post" }, { name: "ATProto record", uri: `at://${did}/site.standard.document/post` }] } };
  const conference = { uri: `at://${did}/${collection}/conference`, cid, value: { $type: collection, name: "Real Conference", createdAt: "2026-08-12T17:51:07Z", startsAt: "2026-09-23T17:00:00Z", endsAt: "2026-09-23T18:00:00Z", createdWith: "https://atmo.rsvp" } };
  const pds = spyOn(Atproto, "createOAuthAgent").mockReturnValue({ com: { atproto: { repo: { listRecords: async (args: { collection: string }) => ({ data: { records: args.collection === collection ? [article, conference] : [] } }) } } } } as unknown as Agent);
  restores.push(() => pds.mockRestore());
  state.rsvpEvents = await listViewerAtmoEvents({ did } as unknown as OAuthSession);
  state.events = [{ ...event, endedAt: "2026-10-26T23:00:00Z" }];
  await mount();
  expect(screen.queryByRole("button", { name: /First Offprint Test/ })).toBeNull();
  expect(screen.getByRole("button", { name: /Real Conference/ })).toBeTruthy();
  expect(screen.getByRole("button", { name: /Launch.*Ended/ })).toBeTruthy();
  expect(screen.getByText("Past").closest("details")?.querySelectorAll("button").length).toBe(2);
});
