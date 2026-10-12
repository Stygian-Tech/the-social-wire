"use client";

import { floatingGlassClasses } from "@/components/shared/floatingChromeStyles";
import { useEffect, useRef, useState } from "react";
import type { FinanceFeedDefinition } from "@/lib/financeFeedClient";
import { financeTickerSymbols, type FinanceTickerSymbol } from "@/lib/financeTickerSymbols";

const tapeScript = "https://widgets.tradingview-widget.com/w/en/tv-ticker-tape.js";

/** A single official component owns its market display; the app never reads its data. */
export function FinanceTickerMarquee({ feed, hidden }: { feed?: FinanceFeedDefinition; hidden: boolean }) {
    const [paused, setPaused] = useState(false);
    const [reducedMotion, setReducedMotion] = useState(() => typeof window !== "undefined" && !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches);
    const [theme, setTheme] = useState(() => typeof document !== "undefined" && document.documentElement.classList.contains("dark") ? "dark" : "light");
    const symbols = financeTickerSymbols(feed);
    const enabled = !hidden && process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED === "true" && symbols.length > 0;

    useEffect(() => {
        const observer = new window.MutationObserver(() => setTheme(document.documentElement.classList.contains("dark") ? "dark" : "light"));
        observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
        const media = window.matchMedia?.("(prefers-reduced-motion: reduce)");
        const updateMotion = () => setReducedMotion(!!media?.matches);
        media?.addEventListener("change", updateMotion);
        return () => { observer.disconnect(); media?.removeEventListener("change", updateMotion); };
    }, []);

    if (!enabled) return null;
    const staticDisplay = paused || reducedMotion;
    const config = JSON.stringify({ symbols: symbols.map(symbol => symbol.proName).join(","), theme });
    // The provider owns its attribution row; reserve space beside it on narrow tickers.
    return (
        <section data-topic-topbar aria-label="Market Ticker" className={`@container sticky top-4 z-20 m-4 shrink-0 overflow-hidden ${floatingGlassClasses}`}>
            {staticDisplay ? (
                <nav aria-label="Ticker Stocks" className="flex gap-4 overflow-x-auto px-4 py-3 text-sm">
                    {symbols.map(symbol => <TickerLink key={symbol.instrumentID} symbol={symbol} />)}
                </nav>
            ) : <div className="pb-1 pr-28 @[28rem]:pr-0"><FinanceTickerEmbed key={config} config={config} /></div>}
            <div className={`flex items-center gap-3 px-3 text-xs text-muted-foreground ${staticDisplay ? "justify-between py-1" : "absolute right-0 bottom-0 pb-0.5"}`}>
                {staticDisplay ? <TickerAttribution /> : null}
                {!reducedMotion ? <button type="button" className="shrink-0 cursor-pointer rounded px-2 py-0.5 hover:bg-muted focus-visible:outline focus-visible:outline-2" onClick={() => setPaused(value => !value)}>{paused ? "Resume Ticker" : "Pause Ticker"}</button> : <span className="shrink-0">Motion Reduced</span>}
            </div>
        </section>
    );
}

function TickerAttribution() {
    return <div className="tradingview-widget-copyright"><a href="https://www.tradingview.com/markets/" target="_blank" rel="noopener nofollow noreferrer"><span className="blue-text">Ticker Tape by TradingView</span></a></div>;
}

function TickerLink({ symbol }: { symbol: FinanceTickerSymbol }) {
    return <a className="shrink-0 hover:underline" href={`/read?feed=finance&financeFeed=${encodeURIComponent(`instrument:${symbol.instrumentID}`)}`}>{symbol.proName.split(":")[1]} <span className="text-muted-foreground">{symbol.title}</span></a>;
}

export function FinanceTickerEmbed({ config }: { config: string }) {
    const host = useRef<HTMLDivElement>(null);
    const widget = useRef<HTMLDivElement>(null);
    const [visible, setVisible] = useState(false);
    const [unavailable, setUnavailable] = useState(false);
    useEffect(() => {
        if (!host.current) return;
        const observer = new IntersectionObserver(rows => {
            if (rows.some(row => row.isIntersecting)) { setVisible(true); observer.disconnect(); }
        });
        observer.observe(host.current);
        return () => observer.disconnect();
    }, []);
    useEffect(() => {
        const element = host.current;
        const target = widget.current;
        if (!visible || !element || !target) return;
        let active = true;
        const timer = window.setTimeout(() => { if (active) setUnavailable(true); }, 12000);
        const { symbols, theme } = JSON.parse(config) as { symbols: string; theme: string };
        // The provider owns this element's closed shadow root. Only public attributes/tokens are set.
        const tape = document.createElement("tv-ticker-tape");
        tape.setAttribute("symbols", symbols);
        tape.setAttribute("theme", theme);
        tape.setAttribute("item-size", "compact");
        tape.setAttribute("aria-label", "TradingView Market Ticker");
        tape.style.display = "block";
        tape.style.width = "100%";
        tape.style.colorScheme = theme;
        tape.style.setProperty("--tv-widget-background-color", "transparent");
        target.appendChild(tape);
        const fail = () => { if (active) { window.clearTimeout(timer); setUnavailable(true); } };
        const ready = () => { if (active) { window.clearTimeout(timer); setUnavailable(false); } };
        let script: HTMLScriptElement | undefined;
        if (window.customElements.get("tv-ticker-tape")) {
            ready();
        } else {
            script = document.createElement("script");
            script.src = tapeScript;
            script.type = "module";
            script.addEventListener("error", fail);
            target.appendChild(script);
            // Definition confirms module readiness, not prices, exchange availability, or freshness.
            void window.customElements.whenDefined("tv-ticker-tape").then(ready, fail);
        }
        return () => { active = false; window.clearTimeout(timer); script?.removeEventListener("error", fail); script?.remove(); target.replaceChildren(); };
    }, [config, visible]);
    return <div ref={host}>
        <div ref={widget} hidden={unavailable} className="tradingview-widget-container min-h-[46px]" />
        {unavailable ? <div className="px-4 py-2 text-xs text-muted-foreground">
            <p role="status">Market Data Is Unavailable. You Can Continue Reading.</p>
            <TickerAttribution />
        </div> : null}
    </div>;
}
