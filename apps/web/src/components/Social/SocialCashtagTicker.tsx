"use client";

import { useEffect, useState } from "react";
import { FinanceTickerEmbed } from "@/components/FinanceTickerMarquee";

export function SocialCashtagTicker({ symbols }: { symbols: string }) {
  const [theme, setTheme] = useState(() => typeof document !== "undefined" && document.documentElement.classList.contains("dark") ? "dark" : "light");
  const [reducedMotion, setReducedMotion] = useState(() => typeof window !== "undefined" && !!window.matchMedia?.("(prefers-reduced-motion: reduce)").matches);
  useEffect(() => {
    const observer = new window.MutationObserver(() => setTheme(document.documentElement.classList.contains("dark") ? "dark" : "light"));
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    const media = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    const update = () => setReducedMotion(!!media?.matches);
    media?.addEventListener("change", update);
    return () => { observer.disconnect(); media?.removeEventListener("change", update); };
  }, []);
  const config = JSON.stringify({ symbols, theme });
  return <section aria-label="Cashtag Market Ticker" onClick={event => event.stopPropagation()} className="min-w-0 overflow-hidden rounded-xl border [&_iframe]:bg-background dark:[&_iframe]:bg-[#080808]">
    {reducedMotion ? <div className="flex flex-wrap gap-3 p-3 text-sm">{symbols.split(",").map(symbol => <a key={symbol} href={`https://www.tradingview.com/symbols/${symbol.replace(":", "-")}/`} target="_blank" rel="noopener noreferrer">${symbol.split(":")[1]}</a>)}</div> : <FinanceTickerEmbed key={config} config={config} />}
    {reducedMotion ? <div className="tradingview-widget-copyright px-3 py-1 text-xs text-muted-foreground"><a href="https://www.tradingview.com/markets/" target="_blank" rel="noopener nofollow noreferrer">Ticker Tape by TradingView</a></div> : null}
  </section>;
}
