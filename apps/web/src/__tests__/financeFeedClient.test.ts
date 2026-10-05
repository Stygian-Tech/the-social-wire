import { describe, expect, spyOn, test } from "bun:test";
import { getFinance, financeCashtags, financePreferenceFingerprint, financeSelectionKey, insertFinanceCashtag, reorderFinanceItems, type FinanceItem } from "@/lib/financeFeedClient";
import * as WireClient from "@/lib/wireFeedClient";
import { mergePreferencesRecord } from "@/lib/pdsClient";
const article = (id: string, global = false, instrument?: string): FinanceItem => ({ story: { itemId: id, canonicalUrl: `https://example.com/${id}`, title: id, source: { name: "Example", domain: "example.com" }, reasons: [], provenance: [] }, majorGlobal: global, sectorIDs: [], instruments: instrument ? [{ instrument: { id: instrument, name: instrument, symbol: instrument, kind: "equity" }, confidenceBps: 9900, prominence: 1 }] : [] });
describe("Finance client invariants", () => {
    test("selection identities include kind, are deterministic and do not depend on symbol", async () => { const id = await financeSelectionKey("instrument", "opaque-1"); expect(id).toHaveLength(64); expect(await financeSelectionKey("instrument", "opaque-1")).toBe(id); expect(await financeSelectionKey("sector", "opaque-1")).not.toBe(id); });
    test("preference context canonicalizes order and duplicates", () => { const selection = { kind: "instrument" as const, reference: "a", createdAt: "now", updatedAt: "now" }; expect(financePreferenceFingerprint([selection, selection])).toBe(financePreferenceFingerprint([selection])); });
    test("reordering boosts selected instruments and reserves a major global item every fifth position", () => { const items = Array.from({ length: 10 }, (_, i) => article(String(i), i === 9, i === 1 ? "AAPL" : undefined)); const result = reorderFinanceItems(items, [{ kind: "instrument", reference: "AAPL", createdAt: "now", updatedAt: "now" }]); expect(result[0]?.story.itemId).toBe("1"); expect(result[4]?.story.itemId).toBe("9"); expect(new Set(result.map(i => i.story.itemId)).size).toBe(10); });
    test("suggestions require confident validated symbols and stay opt in", () => { const item = article("1", false, "AAPL"); item.instruments.push({ instrument: { id: "ambiguous", name: "Cat", symbol: "CAT", kind: "equity" }, confidenceBps: 6000, prominence: 10 }); expect(financeCashtags(item)).toEqual(["$AAPL"]); expect(insertFinanceCashtag("My Comment", "$AAPL")).toBe("My Comment $AAPL"); expect(insertFinanceCashtag("My Comment $aapl", "$AAPL")).toBe("My Comment $aapl"); });
    test("unrelated preference updates retain hidden feed and performance preferences", () => { const original = mergePreferencesRecord({ showFinance: false, hideFinancePerformance: true }, null); const changed = mergePreferencesRecord({ rssArticleOpenMode: "reader" }, original); expect(changed.showFinance).toBe(false); expect(changed.hideFinancePerformance).toBe(true); });
    test("scopes requests and continuation to the selected feed and rejects a mismatched response", async () => {
        const paths: string[] = [];
        const fetch = spyOn(WireClient, "discoveryGatewayFetch").mockImplementation(async ({path}) => {
            paths.push(path);
            return Response.json({feedId:"instrument:apple",items:[]});
        });
        try {
            await getFinance({feed:"instrument:apple",cursor:"apple-cursor",language:"en",hideCrypto:true});
            const request = new URL(paths[0]!, "https://example.com");
            expect(request.searchParams.get("feed")).toBe("instrument:apple");
            expect(request.searchParams.get("cursor")).toBe("apple-cursor");
            expect(request.searchParams.get("lang")).toBe("en");
            expect(request.searchParams.get("hideCrypto")).toBe("true");
            await expect(getFinance({feed:"industry:pharma"})).rejects.toThrow("different feed");
        } finally { fetch.mockRestore(); }
    });

});
