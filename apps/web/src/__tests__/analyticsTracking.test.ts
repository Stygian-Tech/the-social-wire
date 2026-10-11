import { afterEach, expect, it, mock } from "bun:test";
import { analyticsExposureVisible, analyticsSubject, observeAnalyticsTraffic, type AnalyticsEvent } from "@/lib/analyticsTracking";

const uri = "at://did:plc:alice/app.bsky.feed.post/abc";
const original = Object.getOwnPropertyDescriptor(globalThis, "IntersectionObserver");
let callback: IntersectionObserverCallback;
let stopped: (() => void) | undefined;
afterEach(() => {
  stopped?.(); stopped = undefined; document.body.replaceChildren();
  if (original) Object.defineProperty(globalThis, "IntersectionObserver", original); else Reflect.deleteProperty(globalThis, "IntersectionObserver");
});
function setup() {
  const disconnect = mock(() => {});
  const observe = mock<(element: Element) => void>(() => {});
  const unobserve = mock<(element: Element) => void>(() => {});
  Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: class {
    constructor(cb: IntersectionObserverCallback) { callback = cb; }
    observe = observe; unobserve = unobserve; disconnect = disconnect;
  } });
  const card = document.createElement("article"); card.dataset.analyticsSubject = uri; card.dataset.analyticsSurface = "post-viewer";
  card.innerHTML = '<a href="https://publisher.example/story">Original</a><a href="/social">Internal</a>';
  document.body.append(card);
  const emit = mock((event: AnalyticsEvent) => { void event; }); stopped = observeAnalyticsTraffic(emit);
  const entry = { target: card, isIntersecting: true, boundingClientRect: { height: 400, width: 600 }, intersectionRect: { height: 300, width: 600 } } as unknown as IntersectionObserverEntry;
  return { card, emit, entry, disconnect, observe, unobserve };
}
it("validates canonical content identifiers and labels only measured surfaces", () => {
  const card = document.createElement("article"); card.dataset.analyticsSubject = uri; card.dataset.analyticsSurface = "messages";
  expect(analyticsSubject(card)).toEqual({ subjectUri: uri, surface: "messages" });
  card.dataset.analyticsSubject = "https://publisher.example"; expect(analyticsSubject(card)).toBeUndefined();
  card.dataset.analyticsSubject = uri; card.dataset.analyticsSurface = "private-chat"; expect(analyticsSubject(card)).toBeUndefined();
});
it("excludes content inside an account management workspace", () => {
  const workspace = document.createElement("div"); workspace.dataset.analyticsIgnore = "";
  const card = document.createElement("article"); card.dataset.analyticsSubject = uri; card.dataset.analyticsSurface = "post-viewer";
  workspace.append(card);
  expect(analyticsSubject(card)).toBeUndefined();
});
it("requires useful horizontal and vertical exposure even for tall cards", () => {
  expect(analyticsExposureVisible({ isIntersecting: true, boundingClientRect: { height: 2000, width: 600 }, intersectionRect: { height: 201, width: 600 } } as IntersectionObserverEntry)).toBe(true);
  expect(analyticsExposureVisible({ isIntersecting: true, boundingClientRect: { height: 2000, width: 600 }, intersectionRect: { height: 180, width: 600 } } as IntersectionObserverEntry)).toBe(false);
  expect(analyticsExposureVisible({ isIntersecting: false, boundingClientRect: { height: 400, width: 600 }, intersectionRect: { height: 400, width: 600 } } as IntersectionObserverEntry)).toBe(false);
});
it("deduplicates an exposed post, records its view, and sends no destination URL", async () => {
  const { card, emit, entry } = setup();
  callback([entry], {} as IntersectionObserver); await new Promise(r => setTimeout(r, 1100));
  callback([entry], {} as IntersectionObserver); await new Promise(r => setTimeout(r, 1100));
  expect(emit.mock.calls).toEqual([[{ subjectUri: uri, surface: "post-viewer", event: "impression" }], [{ subjectUri: uri, surface: "post-viewer", event: "view" }]]);
  document.addEventListener("click", event => event.preventDefault(), { once: true });
  card.querySelectorAll("a")[0].dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  document.addEventListener("click", event => event.preventDefault(), { once: true });
  card.querySelectorAll("a")[1].dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  expect(emit).toHaveBeenCalledTimes(3);
  expect(emit.mock.calls[2]).toEqual([{ subjectUri: uri, surface: "post-viewer", event: "outbound_click" }]);
});
it("cancels pending exposures when a card leaves the screen and disconnects on account cleanup", async () => {
  const { emit, entry, disconnect } = setup();
  callback([entry], {} as IntersectionObserver);
  callback([{ ...entry, isIntersecting: false }], {} as IntersectionObserver);
  await new Promise(r => setTimeout(r, 1100)); expect(emit).not.toHaveBeenCalled();
  callback([entry], {} as IntersectionObserver); stopped?.(); stopped = undefined;
  await new Promise(r => setTimeout(r, 1100)); expect(emit).not.toHaveBeenCalled(); expect(disconnect).toHaveBeenCalledTimes(1);
});
it("restarts exposure when the reader reuses a visible element for another article", async () => {
  const { card, emit, entry, observe, unobserve } = setup();
  callback([entry], {} as IntersectionObserver);
  card.dataset.analyticsSubject = "at://did:plc:alice/site.standard.document/new";
  await new Promise(resolve => setTimeout(resolve, 0));
  expect(unobserve).toHaveBeenCalledWith(card);
  expect(observe).toHaveBeenCalledTimes(2);
  await new Promise(resolve => setTimeout(resolve, 1100));
  expect(emit).not.toHaveBeenCalled();
  callback([entry], {} as IntersectionObserver);
  await new Promise(resolve => setTimeout(resolve, 1100));
  expect(emit.mock.calls[0]?.[0]).toMatchObject({ subjectUri: "at://did:plc:alice/site.standard.document/new", event: "impression" });
});
