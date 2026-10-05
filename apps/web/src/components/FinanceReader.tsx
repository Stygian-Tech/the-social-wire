"use client";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "@/hooks/useAuth";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { ArticleContent } from "@/components/EntryDetail/ArticleContent";
import { ArticleSocialToolbar } from "@/components/EntryDetail/ArticleSocialToolbar";
import { FinanceTradingView } from "@/components/FinanceTradingView";
import { getWireItem } from "@/lib/wireFeedClient";
import { sanitizeHTMLWithLinks } from "@/lib/sanitize";
import { outboundLinkProps } from "@/lib/outboundLinks";
import type { EntryListItem } from "@/lib/atprotoClient";
export function FinanceReader({ entry, hidePerformance, widgetsEnabled, onClose }: {
    entry: EntryListItem | null;
    hidePerformance: boolean;
    widgetsEnabled: boolean;
    onClose: () => void;
}) {
    const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
    const itemId = entry?.wireItem?.itemId;
    const detail = useQuery({ queryKey: ["financeArticle", itemId, session?.did ?? "public", oauthSessionReloadSeq], queryFn: ({ signal }) => getWireItem(itemId!, { signal, oauthSession: getOAuthSession() ?? undefined }), enabled: !!itemId, staleTime: 0, gcTime: 60000 });
    const primary = [...(entry?.financeItem?.instruments ?? [])].filter(a => a.confidenceBps >= 9000).sort((a, b) => a.prominence - b.prominence)[0]?.instrument;
    return <Dialog open={!!entry} onOpenChange={open => { if (!open)
        onClose(); }}><DialogContent className="max-h-[90svh] max-w-3xl overflow-y-auto"><DialogHeader><DialogTitle>{entry?.title}</DialogTitle></DialogHeader>{entry ? <ArticleSocialToolbar entry={{ ...entry, contentHtml: detail.data?.html ?? "" }}/> : null}<FinanceTradingView symbol={primary?.tradingViewSymbol} hidden={hidePerformance} widgetsEnabled={widgetsEnabled}/>{detail.isLoading ? <p role="status">Loading Article…</p> : detail.data?.html ? <ArticleContent html={sanitizeHTMLWithLinks(detail.data.html)}/> : <p className="text-sm text-muted-foreground">Read this article on the original site.</p>}{entry?.originalUrl ? <a href={entry.originalUrl} {...outboundLinkProps} className="text-primary underline">Open Original Article</a> : null}</DialogContent></Dialog>;
}
