import type { FinanceFeedDefinition } from "@/lib/financeFeedClient";

export type FinanceTickerSymbol = { instrumentID: string; proName: string; title: string };

/** Reviewed presentation references: never inferred from an exchange code or ticker search.
 * Symbols were checked against TradingView's NASDAQ company pages on 2026-10-02.
 * These references do not activate catalog mappings or provide app-owned market data.
 */
const reviewedSymbols: readonly FinanceTickerSymbol[] = [
    { instrumentID: "fin_3a1bcf8223e43dac49e2c7f51ed38c6e", proName: "NASDAQ:AAPL", title: "Apple" },
    { instrumentID: "fin_50a6236ccc20bd5e0d6034d337b53859", proName: "NASDAQ:MSFT", title: "Microsoft" },
    { instrumentID: "fin_2aa18b6a4ac3b19d3cb4bb2a048f4869", proName: "NASDAQ:NVDA", title: "NVIDIA" },
    { instrumentID: "fin_b166610d3554341f2934a000b18ac71d", proName: "NASDAQ:AMZN", title: "Amazon" },
    { instrumentID: "fin_d0af144457231a3924cc3e5294ddf62e", proName: "NASDAQ:GOOGL", title: "Alphabet" },
    { instrumentID: "fin_c6c14909e3db56e2ccf55c52f14f28ad", proName: "NASDAQ:META", title: "Meta" },
    { instrumentID: "fin_fce995f98729bbd784451248a8d93af6", proName: "NASDAQ:TSLA", title: "Tesla" },
];

export function financeTickerSymbols(feed?: FinanceFeedDefinition): readonly FinanceTickerSymbol[] {
    if (!feed || feed.id === "finance" && feed.kind === "all") return reviewedSymbols;
    return reviewedSymbols.filter(symbol => feed.instrumentIDs.includes(symbol.instrumentID));
}
