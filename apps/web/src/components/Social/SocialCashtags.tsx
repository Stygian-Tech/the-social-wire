"use client";

import type { AppBskyFeedPost } from "@atproto/api";
import { SocialCashtagTicker } from "./SocialCashtagTicker";
import { socialCashtagSymbols } from "@/lib/socialCashtags";

export function SocialCashtags({ record }: { record: AppBskyFeedPost.Record }) {
  if (process.env.NEXT_PUBLIC_FINANCE_TICKER_ENABLED !== "true") return null;
  const symbols = socialCashtagSymbols(record);
  if (!symbols.length) return null;
  return <SocialCashtagTicker symbols={symbols.map(symbol => symbol.proName).join(",")} />;
}

