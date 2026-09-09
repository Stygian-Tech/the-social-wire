"use client";
import { useEffect, useMemo, useState } from "react";
import type { OutboxState } from "@thesocialwire/read-state";
import { useAuth } from "@/hooks/useAuth";
import { pendingReadStateOverlay } from "@/lib/pendingReadStateOverlay";
import { PDS_READ_STATE_SYNC_EVENT, pdsReadStateEnabled, pdsReadStateSync } from "@/lib/pdsReadStateSync";

/** Restore pending intent on mount and foreground, independent of feed refreshes. */
export function usePendingPDSReadState() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const viewer = session?.did; const enabled = pdsReadStateEnabled();
  const [snapshot, setSnapshot] = useState<OutboxState>();
  useEffect(() => {
    if (!enabled) return;
    const oauth = getOAuthSession(); if (!oauth || oauth.did !== viewer) return;
    let current = true; let revision = 0;
    const refresh = async () => {
      const requested = ++revision;
      try {
        const next = await pdsReadStateSync(oauth).snapshot();
        if (current && requested === revision && getOAuthSession() === oauth) setSnapshot(next);
      } catch { /* Keep the last durable snapshot while local storage is unavailable. */ }
    };
    const changed = (event: Event) => {
      if ((event as CustomEvent<{ viewerDid: string }>).detail?.viewerDid === viewer) void refresh();
    };
    const visible = () => { if (document.visibilityState === "visible") void refresh(); };
    void refresh(); window.addEventListener(PDS_READ_STATE_SYNC_EVENT, changed);
    document.addEventListener("visibilitychange", visible);
    return () => { current = false; window.removeEventListener(PDS_READ_STATE_SYNC_EVENT, changed); document.removeEventListener("visibilitychange", visible); };
  }, [enabled, getOAuthSession, oauthSessionReloadSeq, viewer]);
  return useMemo(() => pendingReadStateOverlay(enabled ? snapshot : undefined, viewer), [enabled, snapshot, viewer]);
}
