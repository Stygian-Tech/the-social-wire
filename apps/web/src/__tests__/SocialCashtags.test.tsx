import { afterEach, beforeEach, expect, it, mock } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { SocialCashtags } from "@/components/Social/SocialCashtags";
const oldFlag = process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED;
const oldObserver = Object.getOwnPropertyDescriptor(globalThis, "IntersectionObserver");
const oldMedia = Object.getOwnPropertyDescriptor(window, "matchMedia");
let intersect: IntersectionObserverCallback;
let reduce: boolean;
beforeEach(() => {
  process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = "true";
  reduce = false;
  document.documentElement.classList.remove("dark");
  Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ matches: reduce, addEventListener() {}, removeEventListener() {} }) });
  class Observer {
    constructor(callback: IntersectionObserverCallback) { intersect = callback; }
    observe = mock(() => {});
    disconnect = mock(() => {});
  }
  Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: Observer });
});
afterEach(() => {
  cleanup();
  if (oldFlag === undefined) delete process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED; else process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = oldFlag;
  if (oldObserver) Object.defineProperty(globalThis, "IntersectionObserver", oldObserver); else Reflect.deleteProperty(globalThis, "IntersectionObserver");
  if (oldMedia) Object.defineProperty(window, "matchMedia", oldMedia); else Reflect.deleteProperty(window, "matchMedia");
  document.documentElement.classList.remove("dark");
});
const record = { $type: "app.bsky.feed.post" as const, text: "$AAPL $NVDA", createdAt: "2026-10-10T00:00:00Z" };
it("reuses compact official ticker markup only after entering the viewport", async () => {
  const { container, unmount } = render(<SocialCashtags record={record} />);
  expect(container.querySelector("tv-ticker-tape")).toBeNull();
  await act(async () => intersect([{ isIntersecting: true } as IntersectionObserverEntry], {} as IntersectionObserver));
  await waitFor(() => expect(container.querySelector("tv-ticker-tape")).not.toBeNull());
  const tape = container.querySelector("tv-ticker-tape")!;
  expect(tape.getAttribute("symbols")).toBe("NASDAQ:AAPL,NASDAQ:NVDA");
  expect(tape.getAttribute("item-size")).toBe("compact");
  expect(container.querySelector("script")?.getAttribute("src")).toBe("https://widgets.tradingview-widget.com/w/en/tv-ticker-tape.js");
  expect(screen.queryByRole("link", { name: "Ticker Tape by TradingView" })).toBeNull();
  unmount(); expect(container.querySelector("script")).toBeNull();
});
it("does not load provider scripts for unsupported tags, disabled widgets, or reduced motion", () => {
  const view = render(<SocialCashtags record={{ ...record, text: "#AAPL $UNKNOWN" }} />);
  expect(view.container.querySelector("section")).toBeNull();
  process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = "false";
  view.rerender(<SocialCashtags record={record} />);
  expect(view.container.querySelector("section")).toBeNull();
  process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = "true";
  reduce = true;
  view.rerender(<SocialCashtags record={record} />);
  expect(view.container.querySelector("script")).toBeNull();
  expect(screen.getAllByRole("link", { name: "Ticker Tape by TradingView" })).toHaveLength(1);
  expect(screen.getByRole("link", { name: "$AAPL" }).getAttribute("href")).toBe("https://www.tradingview.com/symbols/NASDAQ-AAPL/");
});
it("keeps provider interactions from opening the containing post", async () => {
  const open = mock(() => {});
  const view = render(<div onClick={open}><SocialCashtags record={record} /></div>);
  await act(async () => intersect([{ isIntersecting: true } as IntersectionObserverEntry], {} as IntersectionObserver));
  fireEvent.click(view.container.querySelector("tv-ticker-tape")!);
  expect(open).not.toHaveBeenCalled();
});
