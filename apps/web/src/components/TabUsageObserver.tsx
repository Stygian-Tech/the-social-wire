"use client";

import { useEffect, useRef } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import { useAuth } from "@/hooks/useAuth";
import { loadReaderFeedSelection } from "@/lib/readerFeedSelectionStorage";
import { getStoredOAuthDid } from "@/lib/auth";
import { canonicalUsageTab, recordTabUsage, tabUsageClock } from "@/lib/tabUsageTelemetry";

function rememberedReaderFeed() {
  try { return typeof window === "undefined" ? null : loadReaderFeedSelection(window.localStorage); }
  catch { return null; }
}

export function TabUsageObserver() {
  const pathname = usePathname(), params = useSearchParams();
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const remembered = rememberedReaderFeed();
  const tab = canonicalUsageTab(pathname ?? "", params?.get("folder") ? "subscribed" : params?.get("feed") ?? remembered);
  const owner = session?.did;
  const lastVisit = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!owner || !tab || navigator.doNotTrack === "1") { lastVisit.current = undefined; return; }
    const visit = JSON.stringify([owner, tab]);
    const clock = tabUsageClock(tab, () => performance.now(), sample => {
      const oauth = getOAuthSession();
      if (!oauth || oauth.did !== owner || getStoredOAuthDid() !== owner || navigator.doNotTrack === "1") return;
      if (sample.event === "tab_open") {
        if (lastVisit.current === visit) return;
        lastVisit.current = visit;
      }
      void recordTabUsage(oauth, sample).catch(() => { /* Telemetry never blocks navigation. */ });
    });
    const visibility = () => document.visibilityState === "visible" ? clock.visible() : clock.hidden();
    const pageHide = () => clock.hidden();
    visibility();
    document.addEventListener("visibilitychange", visibility);
    window.addEventListener("pagehide", pageHide);
    const timer = window.setInterval(clock.flush, 30_000);
    return () => { clock.hidden(); window.clearInterval(timer); document.removeEventListener("visibilitychange", visibility); window.removeEventListener("pagehide", pageHide); };
  }, [owner, tab, getOAuthSession, oauthSessionReloadSeq]);
  return null;
}
