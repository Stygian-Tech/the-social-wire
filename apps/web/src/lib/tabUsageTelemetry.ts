import type { OAuthSession } from "@atproto/oauth-client-browser";
import { getAppEnv } from "@/lib/appEnv";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export const USAGE_TABS = ["home", "explore", "notifications", "messages", "bookmarks", "lists", "feeds", "saved", "archive", "wire", "circle", "finance", "sports", "subscribed", "following", "podcasts", "articles", "live-post", "livestream", "brand-accounts", "analytics", "profile", "content-calendar"] as const;
export type UsageTab = typeof USAGE_TABS[number];
export type TabUsageSample = { event: "tab_open" | "tab_dwell"; tab: UsageTab; durationMs: number };

/** Raw paths, queries, publication IDs and handles never enter the payload. */
export function canonicalUsageTab(pathname: string, feed?: string | null): UsageTab | undefined {
  if (pathname === "/read" || pathname.startsWith("/read/")) return ["wire", "circle", "finance", "sports", "following"].includes(feed ?? "") ? feed as UsageTab : "subscribed";
  if (pathname === "/social") return "home";
  if (pathname === "/social/profile") return "profile";
  const social = /^\/social\/(explore|notifications|messages|bookmarks|lists|feeds)(?:\/|$)/.exec(pathname);
  if (social) return social[1] as UsageTab;
  if (pathname === "/me" || pathname.startsWith("/me/")) return "profile";
  const root = /^\/(saved|archive|podcasts|articles|live-post|livestream|brand-accounts|analytics|content-calendar)(?:\/|$)/.exec(pathname);
  return root?.[1] as UsageTab | undefined;
}

export function recordTabUsage(session: OAuthSession, sample: TabUsageSample): Promise<Response> {
  const environment = getAppEnv();
  return gatewayFetch(session, "/v1/telemetry/client-performance", { method: "POST", headers: { "Content-Type": "application/json" }, keepalive: true,
    body: JSON.stringify({ event: sample.event, tab: sample.tab, durationMs: Math.max(0, Math.min(60_000, sample.durationMs)), environment: environment === "prod" ? "production" : environment }),
  });
}

/** Only visible elapsed time is counted; no session or identity is retained here. */
export function tabUsageClock(tab: UsageTab, now: () => number, emit: (sample: TabUsageSample) => void) {
  let since: number | undefined;
  let opened = false;
  function flush() {
    if (since === undefined) return;
    const end = now(), duration = end - since;
    since = end;
    if (duration > 0) emit({ event: "tab_dwell", tab, durationMs: Math.min(duration, 60_000) });
  }
  return {
    visible() { if (since !== undefined) return; since = now(); if (!opened) { opened = true; emit({ event: "tab_open", tab, durationMs: 0 }); } },
    hidden() { flush(); since = undefined; },
    flush,
  };
}
