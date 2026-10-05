import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createOAuthAgent } from "@/lib/atprotoClient";
import { discoveryGatewayFetch, type WireItem, type WirePage } from "@/lib/wireFeedClient";
import { feedResponseError } from "@/lib/feedResponseError";
export type FinanceInstrument = {
    id: string;
    name: string;
    symbol: string;
    kind: string;
    exchange?: string;
    exchangeName?: string;
    mic?: string;
    shareClassFIGI?: string;
    compositeFIGI?: string;
    tradingViewSymbol?: string;
};
export type FinanceAssociation = {
    instrument: FinanceInstrument;
    confidenceBps: number;
    resolverVersion?: string;
    prominence: number;
};
export type FinanceItem = {
    story: WireItem;
    instruments: FinanceAssociation[];
    sectorIDs: string[];
    majorGlobal: boolean;
    materiality?: string;
    macroTopics?: string[];
};
export type FinancePage = Omit<WirePage, "items"> & {
    items: FinanceItem[];
    feedId: string;
    preferenceRevision: string;
    expiresAt: string;
    widgetsEnabled: boolean;
};
export type FinanceSelection = {
    kind: "instrument" | "sector";
    reference: string;
    createdAt: string;
    updatedAt: string;
};
export const FINANCE_SELECTION_COLLECTION = "app.thesocialwire.finance.selection";
const prefix = "/xrpc/app.thesocialwire.discovery.";
async function query<T>(method: string, params: URLSearchParams, oauthSession?: OAuthSession, signal?: AbortSignal): Promise<T> {
    const response = await discoveryGatewayFetch({ path: `${prefix}${method}?${params}`, oauthSession, signal });
    if (!response.ok)
        throw await feedResponseError(response, "Finance could not load");
    return response.json() as Promise<T>;
}
export async function getFinance(args: {
    feed?: string;
    cursor?: string;
    language?: string;
    region?: string;
    refreshSelections?: boolean;
    oauthSession?: OAuthSession;
    signal?: AbortSignal;
}): Promise<FinancePage> {
    const params = new URLSearchParams({ feed: args.feed ?? "finance" });
    if (args.cursor)
        params.set("cursor", args.cursor);
    if (args.language)
        params.set("lang", args.language);
    if (args.region)
        params.set("region", args.region);
    if (args.refreshSelections)
        params.set("refreshSelections", "true");
    const page = await query<FinancePage>("getFinance", params, args.oauthSession, args.signal);
    if (page.feedId !== (args.feed ?? "finance"))
        throw new Error("Finance returned a different feed. Try Refresh.");
    return page;
}
export type FinanceFeedDefinition = {
    id: string;
    title: string;
    kind: "all" | "instrument" | "industry" | "group";
    instrumentIDs: string[];
    sectorIDs: string[];
    description: string;
};
export type FinanceCatalog = {
    enabled: boolean;
    available: boolean;
    widgetsEnabled: boolean;
    feeds: FinanceFeedDefinition[];
};
export const financeTopicIsVisible = (showFinance: boolean, catalog?: Pick<FinanceCatalog, "enabled">) => showFinance && catalog?.enabled === true;
export function getFinanceCatalog(signal?: AbortSignal): Promise<FinanceCatalog> {
    return query("getFinanceCatalog", new URLSearchParams(), undefined, signal);
}
export function searchFinanceInstruments(q: string, signal?: AbortSignal): Promise<{
    instruments: FinanceInstrument[];
}> {
    return query("searchFinanceInstruments", new URLSearchParams({ q }), undefined, signal);
}
export function getFinanceSectors(signal?: AbortSignal): Promise<{
    sectors: {
        id: string;
        name: string;
    }[];
}> {
    return query("getFinanceSectors", new URLSearchParams(), undefined, signal);
}
export function financePreferenceFingerprint(selections: readonly FinanceSelection[]): string {
    return JSON.stringify([...new Set(selections.map(s => `${s.kind}:${s.reference}`))].sort());
}
export async function financeSelectionKey(kind: FinanceSelection["kind"], reference: string): Promise<string> {
    const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${kind}:${reference}`));
    return [...new Uint8Array(hash)].map(byte => byte.toString(16).padStart(2, "0")).join("");
}
export async function listFinanceSelections(oauth: OAuthSession, did: string): Promise<FinanceSelection[]> {
    const agent = createOAuthAgent(oauth);
    const selections: FinanceSelection[] = [];
    let cursor: string | undefined;
    do {
        const page = await agent.com.atproto.repo.listRecords({ repo: did, collection: FINANCE_SELECTION_COLLECTION, limit: 100, cursor });
        for (const row of page.data.records) {
            const value = row.value as Partial<FinanceSelection>;
            if ((value.kind === "instrument" || value.kind === "sector") && typeof value.reference === "string" && typeof value.createdAt === "string" && typeof value.updatedAt === "string")
                selections.push(value as FinanceSelection);
        }
        cursor = page.data.cursor;
    } while (cursor);
    return selections;
}
export async function writeFinanceSelection(oauth: OAuthSession, did: string, selection: FinanceSelection, remove: boolean): Promise<void> {
    const agent = createOAuthAgent(oauth);
    const rkey = await financeSelectionKey(selection.kind, selection.reference);
    if (remove)
        await agent.com.atproto.repo.deleteRecord({ repo: did, collection: FINANCE_SELECTION_COLLECTION, rkey });
    else
        await agent.com.atproto.repo.putRecord({ repo: did, collection: FINANCE_SELECTION_COLLECTION, rkey, record: { $type: FINANCE_SELECTION_COLLECTION, ...selection } });
}
export function reorderFinanceItems(items: readonly FinanceItem[], selections: readonly FinanceSelection[]): FinanceItem[] {
    const instruments = new Set(selections.filter(s => s.kind === "instrument").map(s => s.reference));
    const sectors = new Set(selections.filter(s => s.kind === "sector").map(s => s.reference));
    const ranked = items.map((item, index) => ({ item, index, score: (items.length - index) * (1 + Math.min(.35, (item.instruments.some(a => instruments.has(a.instrument.id)) ? .25 : 0) + (item.sectorIDs.some(id => sectors.has(id)) ? .1 : 0))) })).sort((a, b) => b.score - a.score || a.index - b.index).map(row => row.item);
    const result: FinanceItem[] = [];
    while (ranked.length) {
        const global = result.length % 5 === 4 ? ranked.findIndex(item => item.majorGlobal) : -1;
        result.push(ranked.splice(global < 0 ? 0 : global, 1)[0]!);
    }
    return result;
}
export function financeCashtags(item?: FinanceItem): string[] {
    return [...new Set([...(item?.instruments ?? [])].filter(a => a.confidenceBps >= 9000).sort((a, b) => a.prominence - b.prominence).map(a => a.instrument.symbol).filter(symbol => /^[A-Za-z][A-Za-z0-9.]{0,14}$/.test(symbol)).map(symbol => `$${symbol}`))].slice(0, 3);
}
export function insertFinanceCashtag(text: string, tag: string): string {
    return text.split(/\s+/).some(word => word.toLowerCase() === tag.toLowerCase()) ? text : `${text.trimEnd()}${text.trim() ? " " : ""}${tag}`;
}
export async function recordFinanceComposition(oauth: OAuthSession, event: "impression" | "selection" | "removal" | "published", suggestionCount: number): Promise<void> {
    const { gatewayFetch } = await import("@/lib/socialWireGatewayClient");
    await gatewayFetch(oauth, `${prefix}recordFinanceComposition`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ event, suggestionCount: Math.max(0, Math.min(3, suggestionCount)) }) });
}
