"use client";

import { financeExchangeLabel } from "@/lib/financeExchangeLabel";
import { useQuery } from "@tanstack/react-query";
import { FinanceTradingView } from "@/components/FinanceTradingView";
import { searchFinanceInstruments, type FinanceFeedDefinition, type FinanceItem } from "@/lib/financeFeedClient";

export function FinanceInstrumentOverview({ feed, items, hidden, widgetsEnabled }: {
  feed: FinanceFeedDefinition; items: FinanceItem[]; hidden: boolean; widgetsEnabled: boolean;
}) {
  const instrumentID = feed.instrumentIDs[0];
  const matched = items.flatMap(item => item.instruments).find(association => association.instrument.id === instrumentID && association.confidenceBps >= 9000)?.instrument;
  const identity = useQuery({ queryKey: ["financeInstrumentIdentity", instrumentID, feed.title], queryFn: async ({ signal }) => {
    const result = await searchFinanceInstruments(instrumentID, signal);
    return result.instruments.find(instrument => instrument.id === instrumentID) ?? null;
  }, enabled: !matched, staleTime: 60 * 60000, retry: 1 });
  const instrument = matched ?? identity.data;
  const symbol = instrument?.tradingViewSymbol;
  const exchangeLabel = instrument ? financeExchangeLabel(instrument) : undefined;
  const performanceAvailable = widgetsEnabled && process.env.NEXT_PUBLIC_FINANCE_WIDGETS_ENABLED === "true" && !!symbol && /^[A-Za-z0-9_\-]+:[A-Za-z0-9_.!\-]+$/.test(symbol);
  // These are validated article associations, not an issuer's official IR directory.
  const coverage = [...new Map(items.filter(item => ["earnings", "filing"].includes(item.materiality ?? "") && item.instruments.some(association => association.instrument.id === instrumentID && association.confidenceBps >= 9000)).filter(item => {
    try { return new URL(item.story.canonicalUrl).protocol === "https:"; } catch { return false; }
  }).map(item => [item.story.canonicalUrl, item])).values()].slice(0, 5);

  return <section aria-label="Security Overview" className="mb-7 space-y-4 rounded-xl border bg-muted/20 p-4">
    <div><h2 className="font-semibold">Security Overview</h2>{instrument ? <p className="mt-1 text-sm text-muted-foreground">{instrument.name} · {instrument.symbol}{exchangeLabel ? ` · ${exchangeLabel}` : ""}</p> : <p className="mt-1 text-sm text-muted-foreground">{identity.isPending ? "Resolving Security Details…" : "Additional security details are unavailable."}</p>}</div>
    <div><h3 className="text-sm font-medium">Performance</h3>{hidden ? <p className="mt-2 text-sm text-muted-foreground">Performance data is hidden.</p> : performanceAvailable ? <FinanceTradingView key={symbol} symbol={symbol} hidden={hidden} widgetsEnabled={widgetsEnabled} /> : <p className="mt-2 text-sm text-muted-foreground">Market display is unavailable for this security. Articles remain available below.</p>}</div>
    <div className="space-y-2"><h3 className="text-sm font-medium">Earnings and Reports</h3><p className="text-xs text-muted-foreground">Related reporting from this feed. Verified company report and earnings-call links are not available yet.</p>{coverage.length ? <ul className="space-y-2">{coverage.map(item => <li key={item.story.canonicalUrl}><a href={item.story.canonicalUrl} target="_blank" rel="noopener noreferrer" className="text-sm underline">{item.story.title}</a><p className="text-xs text-muted-foreground">{item.materiality === "filing" ? "Filing Coverage" : "Earnings Coverage"} · {new URL(item.story.canonicalUrl).hostname}</p></li>)}</ul> : <p className="text-sm text-muted-foreground">No earnings or filing coverage in the loaded articles.</p>}</div>
  </section>;
}
