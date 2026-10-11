"use client";

import { useEffect } from "react";
import { useAuth } from "@/hooks/useAuth";
import { observeAnalyticsTraffic, type AnalyticsEvent } from "@/lib/analyticsTracking";
import { listBrandAccounts } from "@/lib/brandAccounts/brandAccountStorage";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export function AnalyticsTrafficObserver() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did;
  useEffect(() => {
    if (!did || navigator.doNotTrack === "1") return;
    const ac = new AbortController();
    let queue = Promise.resolve();
    let queued = 0;
    const emit = (event: AnalyticsEvent) => {
      if (queued >= 30 || ac.signal.aborted || listBrandAccounts(did).some(brand => event.subjectUri.startsWith(`at://${brand}/`))) return;
      queued++;
      queue = queue.then(async () => {
        if (ac.signal.aborted) return;
        const oauth = await getOAuthSession();
        if (!oauth || oauth.did !== did || ac.signal.aborted) return;
        await gatewayFetch(oauth, "/v1/analytics/events", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(event), signal: ac.signal });
      }).catch(() => { /* Analytics must never interrupt reading or navigation. */ }).finally(() => { queued--; });
    };
    const stop = observeAnalyticsTraffic(emit);
    return () => { ac.abort(); stop(); };
  }, [did, getOAuthSession]);
  return null;
}
