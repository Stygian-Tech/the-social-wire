"use client";

import { useCallback, useEffect, useState } from "react";
import type { OutboxState, ReadStateStatus } from "@thesocialwire/read-state";
import { useAuth } from "@/hooks/useAuth";
import { PDS_READ_STATE_SYNC_EVENT, pdsReadStateEnabled, pdsReadStateSync } from "@/lib/pdsReadStateSync";

export function usePDSReadStateStatus() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const viewer = session?.did;
  const [snapshot, setSnapshot] = useState<{ viewer?: string; status?: ReadStateStatus; outbox?: OutboxState; error?: string; migrating?: boolean }>({});
  const enabled = pdsReadStateEnabled();
  useEffect(() => {
    if (!enabled) return;
    const oauth = getOAuthSession(); if (!oauth || oauth.did !== viewer) return;
    const runtime = pdsReadStateSync(oauth); const release = runtime.retain(); let current = true;
    const refresh = async () => {
      try {
        const [status, outbox] = await Promise.all([runtime.status(), runtime.snapshot()]);
        if (current) setSnapshot({ viewer, status, outbox, error: runtime.localError });
      } catch { if (current) setSnapshot(previous => ({ ...previous, viewer, error: "Read history sync is unavailable. Your saved pending changes will retry." })); }
    };
    const changed = (event: Event) => {
      if ((event as CustomEvent<{ viewerDid: string }>).detail?.viewerDid === viewer) void refresh();
    };
    const reconnect = () => { void runtime.bootstrap().then(refresh).catch(async () => {
      await refresh();
      if (current) setSnapshot(previous => ({ ...previous, viewer,
        error: "Read history sync is unavailable. Saved pending changes remain on this device and will retry." }));
    }); };
    reconnect();
    window.addEventListener(PDS_READ_STATE_SYNC_EVENT, changed);
    window.addEventListener("online", reconnect);
    const visible = () => { if (document.visibilityState === "visible") reconnect(); };
    document.addEventListener("visibilitychange", visible);
    return () => {
      current = false; release(); window.removeEventListener(PDS_READ_STATE_SYNC_EVENT, changed);
      window.removeEventListener("online", reconnect); document.removeEventListener("visibilitychange", visible);
    };
  }, [enabled, getOAuthSession, oauthSessionReloadSeq, viewer]);
  const migrate = useCallback(async () => {
    const oauth = getOAuthSession(); if (!oauth || oauth.did !== viewer) return;
    setSnapshot(previous => ({ ...previous, viewer, migrating: true, error: undefined }));
    try {
      const status = await pdsReadStateSync(oauth).migrate();
      if (getOAuthSession() === oauth) setSnapshot(previous => ({ ...previous, viewer, status, migrating: false }));
    } catch {
      if (getOAuthSession() === oauth) setSnapshot(previous => ({ ...previous, viewer, migrating: false,
        error: "Migration is not complete. Existing read history remains protected. Sign in again if access was denied, then retry." }));
    }
  }, [getOAuthSession, viewer]);
  return { enabled, ...(snapshot.viewer === viewer ? snapshot : {}), migrate };
}
