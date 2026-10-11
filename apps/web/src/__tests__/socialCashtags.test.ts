import { expect, it } from "bun:test";
import { socialCashtagSymbols } from "@/lib/socialCashtags";
const record = (text: string) => ({ $type: "app.bsky.feed.post" as const, text, createdAt: "2026-10-10T00:00:00Z" });
it("deduplicates and bounds reviewed cashtags in visible text", () => {
  expect(socialCashtagSymbols(record("$aapl $AAPL, $MSFT. $NVDA! $TSLA $BOGUS $100" )).map(symbol => symbol.proName)).toEqual(["NASDAQ:AAPL", "NASDAQ:MSFT", "NASDAQ:NVDA"]);
});
it("uses UTF-8 native facet cashtags without converting normal hashtags into tickers", () => {
  const text = "👋 $AAPL #MSFT";
  expect(socialCashtagSymbols({ ...record(text), facets: [{ index: { byteStart: 5, byteEnd: 10 }, features: [{ $type: "app.bsky.richtext.facet#tag", tag: "AAPL" }] }] }).map(symbol => symbol.proName)).toEqual(["NASDAQ:AAPL"]);
});
it("avoids code, URL paths, escaped dollars, and unsupported exchange guesses", () => {
  const text = "`$AAPL`\n```\n$NVDA\n```\nhttps://example.test/$TSLA [Website](https://example.test?q=$META) \\$MSFT $BRK.B $FAKE $AAPLfoo";
  expect(socialCashtagSymbols(record(text))).toEqual([]);
  expect(socialCashtagSymbols(record("**$AAPL** and [$MSFT](https://example.test)" )).map(symbol => symbol.proName)).toEqual(["NASDAQ:AAPL", "NASDAQ:MSFT"]);
});
