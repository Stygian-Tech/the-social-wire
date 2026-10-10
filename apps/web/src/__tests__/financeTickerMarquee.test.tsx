import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { FinanceTickerMarquee } from "@/components/FinanceTickerMarquee";
import { financeTickerSymbols } from "@/lib/financeTickerSymbols";
import type { FinanceFeedDefinition } from "@/lib/financeFeedClient";

const originalFlag = process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED;
const originalObserver = globalThis.IntersectionObserver;
const originalMedia = window.matchMedia;
const originalRegistry = window.customElements;
let registered = false;
let defineTape: () => void;
const intersections = new Map<Element, (rows: { isIntersecting: boolean }[]) => void>();
let motionChange: () => void;
let reduced = false;
const feed = (instrumentIDs: string[], kind: FinanceFeedDefinition["kind"] = "instrument"): FinanceFeedDefinition => ({ id: "named-feed", title: "Named Feed", kind, instrumentIDs, sectorIDs: [], description: "" });
const appleID = "fin_3a1bcf8223e43dac49e2c7f51ed38c6e";

beforeEach(() => {
    process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = "true";
    reduced = false;
    intersections.clear();
    registered = false;
    Object.defineProperty(window, "customElements", { configurable: true, value: { get: () => registered ? class {} : undefined, whenDefined: () => new Promise<void>(resolve => { defineTape = () => { registered = true; resolve(); }; }) } });
    document.documentElement.classList.remove("dark");
    Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: class {
        private observed?: Element;
        constructor(private callback: (rows: { isIntersecting: boolean }[]) => void) {}
        observe(element: Element) { this.observed = element; intersections.set(element, this.callback); }
        disconnect() { if (this.observed) intersections.delete(this.observed); }
    } });
    Object.defineProperty(window, "matchMedia", { configurable: true, value: () => ({ get matches() { return reduced; }, addEventListener(_event: string, callback: () => void) { motionChange = callback; }, removeEventListener() {} }) });
});
afterEach(() => {
    cleanup();
    process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = originalFlag;
    Object.defineProperty(globalThis, "IntersectionObserver", { configurable: true, value: originalObserver });
    Object.defineProperty(window, "matchMedia", { configurable: true, value: originalMedia });
    Object.defineProperty(window, "customElements", { configurable: true, value: originalRegistry });
    document.documentElement.classList.remove("dark");
});
const showTicker = async (container: HTMLElement) => {
    await waitFor(() => expect(intersections.has(container.querySelector(".tradingview-widget-container")!.parentElement!)).toBe(true));
    await act(async () => intersections.get(container.querySelector(".tradingview-widget-container")!.parentElement!)!([{ isIntersecting: true }]));
    await waitFor(() => expect(container.querySelector("script")).not.toBeNull());
    return container.querySelector("script")!;
};

describe("Finance Ticker Marquee", () => {
    it("uses seven reviewed presentation references only for the main feed", () => {
        expect(financeTickerSymbols()).toHaveLength(7);
        expect(financeTickerSymbols(feed([appleID]))).toEqual([{ instrumentID: appleID, proName: "NASDAQ:AAPL", title: "Apple" }]);
        expect(financeTickerSymbols(feed(["different-apple-listing"]))).toHaveLength(0);
        expect(financeTickerSymbols(feed([], "industry"))).toHaveLength(0);
        expect(financeTickerSymbols(feed([appleID], "group"))).toHaveLength(1);
    });
    it("omits the entire strip when hidden, disabled, or unsupported", () => {
        const { container, rerender } = render(<FinanceTickerMarquee hidden />);
        expect(container.textContent).toBe("");
        rerender(<FinanceTickerMarquee hidden={false} feed={feed(["unsupported"])} />);
        expect(container.textContent).toBe("");
        process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED = "false";
        rerender(<FinanceTickerMarquee hidden={false} />);
        expect(container.textContent).toBe("");
    });
    it("loads one official script only after visibility, without private configuration", async () => {
        const { container } = render(<FinanceTickerMarquee hidden={false} feed={feed([appleID])} />);
        const strip = screen.getByRole("region", { name: "Market Ticker" });
        expect(strip.classList.contains("floating-glass")).toBe(true);
        expect(strip.classList.contains("m-2")).toBe(true);
        expect(strip.classList.contains("top-2")).toBe(true);
        expect(strip.classList.contains("border-b")).toBe(false);
        expect(container.querySelector("script")).toBeNull();
        const script = await showTicker(container);
        expect(script.src).toBe("https://widgets.tradingview-widget.com/w/en/tv-ticker-tape.js");
        expect(script.type).toBe("module");
        expect(script.textContent).toBe("");
        const tape = container.querySelector("tv-ticker-tape")!;
        expect(tape.getAttribute("symbols")).toBe("NASDAQ:AAPL");
        expect(tape.getAttribute("theme")).toBe("light");
        expect(tape.getAttribute("item-size")).toBe("compact");
        expect(tape.getAttributeNames().sort()).toEqual(["aria-label", "item-size", "style", "symbols", "theme"]);
        expect(screen.getByRole("region", { name: "Market Ticker" }).className).toContain("sticky top-2");
        expect(screen.queryByRole("link", { name: "Ticker Tape by TradingView" })).toBeNull();
    });
    it("replaces the embed on theme and feed changes and removes it when hidden", async () => {
        const { container, rerender } = render(<FinanceTickerMarquee hidden={false} />);
        const old = await showTicker(container);
        await act(async () => { document.documentElement.classList.add("dark"); });
        await waitFor(() => expect(old.isConnected).toBe(false));
        const dark = await showTicker(container);
        expect(old.isConnected).toBe(false);
        expect(dark.type).toBe("module");
        const darkTape = container.querySelector("tv-ticker-tape") as HTMLElement;
        expect(darkTape.getAttribute("theme")).toBe("dark");
        expect(darkTape.style.getPropertyValue("--tv-widget-background-color")).toBe("#080808");
        rerender(<FinanceTickerMarquee hidden={false} feed={feed([appleID])} />);
        const apple = await showTicker(container);
        expect(apple.type).toBe("module");
        expect(container.querySelector("tv-ticker-tape")!.getAttribute("symbols")).toBe("NASDAQ:AAPL");
        expect(container.querySelectorAll("script")).toHaveLength(1);
        rerender(<FinanceTickerMarquee hidden />);
        expect(apple.isConnected).toBe(false);
    });
    it("pauses by removing performance display, with static stock links and attribution", async () => {
        const { container } = render(<FinanceTickerMarquee hidden={false} />);
        const script = await showTicker(container);
        fireEvent.click(screen.getByRole("button", { name: "Pause Ticker" }));
        expect(script.isConnected).toBe(false);
        expect(screen.getByRole("link", { name: "AAPL Apple" }).getAttribute("href")).toBe(`/read?feed=finance&financeFeed=instrument%3A${appleID}`);
        expect(screen.getByRole("link", { name: "Ticker Tape by TradingView" })).not.toBeNull();
        fireEvent.click(screen.getByRole("button", { name: "Resume Ticker" }));
        await showTicker(container);
    });
    it("respects reduced motion initially and when the device setting changes", async () => {
        reduced = true;
        const { container } = render(<FinanceTickerMarquee hidden={false} />);
        expect(container.querySelector("script")).toBeNull();
        expect(screen.getByText("Motion Reduced")).not.toBeNull();
        expect(screen.getAllByRole("link", { name: "Ticker Tape by TradingView" })).toHaveLength(1);
        expect(screen.queryByRole("button", { name: "Resume Ticker" })).toBeNull();
        reduced = false;
        act(() => motionChange());
        await waitFor(() => expect(screen.getByRole("button", { name: "Pause Ticker" })).not.toBeNull());
        const script = await showTicker(container);
        reduced = true;
        act(() => motionChange());
        await waitFor(() => expect(script.isConnected).toBe(false));
    });
    it("keeps reading and attribution available when the embed fails", async () => {
        const { container } = render(<><p>Article Body</p><FinanceTickerMarquee hidden={false} /></>);
        fireEvent.error(await showTicker(container));
        expect(screen.getByRole("status").textContent).toContain("Continue Reading");
        expect(screen.getByText("Article Body")).not.toBeNull();
        expect(screen.getAllByRole("link", { name: "Ticker Tape by TradingView" })).toHaveLength(1);
        expect(container.querySelector(".tradingview-widget-container")!.hasAttribute("hidden")).toBe(true);
        await act(async () => defineTape());
        expect(screen.queryByRole("link", { name: "Ticker Tape by TradingView" })).toBeNull();
        expect(container.querySelector(".tradingview-widget-container")!.hasAttribute("hidden")).toBe(false);
    });

    it("reuses the registered component and removes its provider-owned DOM on hiding", async () => {
        const { container, rerender } = render(<FinanceTickerMarquee hidden={false} />);
        await showTicker(container);
        await act(async () => defineTape());
        expect(container.querySelectorAll("tv-ticker-tape")).toHaveLength(1);
        rerender(<FinanceTickerMarquee hidden />);
        expect(container.querySelector("tv-ticker-tape")).toBeNull();
        rerender(<FinanceTickerMarquee hidden={false} />);
        await waitFor(() => expect(intersections.has(container.querySelector(".tradingview-widget-container")!.parentElement!)).toBe(true));
        await act(async () => intersections.get(container.querySelector(".tradingview-widget-container")!.parentElement!)!([{ isIntersecting: true }]));
        expect(container.querySelectorAll("tv-ticker-tape")).toHaveLength(1);
        expect(container.querySelector("script")).toBeNull();
    });
});
