"use client";

import { useCallback, useEffect, useState } from "react";
import type { OutboxState, ReadStateStatus } from "@thesocialwire/read-state";
import { readStateErrorMessage, readStateStatusMessage } from "@/lib/pdsReadStateMessages";
import { useAuth } from "@/hooks/useAuth";
import type { PDSReadStateSync } from "@/lib/pdsReadStateSync";
import { PDS_READ_STATE_SYNC_EVENT, loadPDSReadStateSync, pdsReadStateEnabled } from "@/lib/pdsReadStateRuntime";

export function usePDSReadStateStatus() {
  const { session, getOAuthSession, oauthSessionReloadSeq } = useAuth();
  const viewer = session?.did;
  const [snapshot, setSnapshot] = useState<{ viewer?: string; status?: ReadStateStatus; outbox?: OutboxState; error?: string; migrating?: boolean }>({});
  const enabled = pdsReadStateEnabled();
  useEffect(() => {
    if (!enabled) return;
    const oauth = getOAuthSession(); if (!oauth || oauth.did !== viewer) return;
    let current = true; let release: (() => void) | undefined;
    // Retain only after the lazily loaded runtime arrives, and never after this effect is gone.
    const loaded: Promise<PDSReadStateSync | undefined> = loadPDSReadStateSync(oauth).then(runtime => {
      if (!current) return undefined;
      release = runtime.retain(); return runtime;
    });
    const refresh = async () => {
      try {
        const runtime = await loaded; if (!runtime) return;
        const [status, outbox] = await Promise.all([runtime.status(), runtime.snapshot()]);
        if (current) setSnapshot({ viewer, status, outbox, error: runtime.localError ?? readStateStatusMessage(status, outbox) });
      } catch { if (current) setSnapshot(previous => ({ ...previous, viewer, error: "Read history sync is unavailable. Your saved pending changes will retry." })); }
    };
    const changed = (event: Event) => {
      if ((event as CustomEvent<{ viewerDid: string }>).detail?.viewerDid === viewer) void refresh();
    };
    const reconnect = () => { void loaded.then(runtime => runtime?.bootstrap()).then(refresh).catch(async () => {
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
      current = false; release?.(); window.removeEventListener(PDS_READ_STATE_SYNC_EVENT, changed);
      window.removeEventListener("online", reconnect); document.removeEventListener("visibilitychange", visible);
    };
  }, [enabled, getOAuthSession, oauthSessionReloadSeq, viewer]);
  const migrate = useCallback(async () => {
    const oauth = getOAuthSession(); if (!oauth || oauth.did !== viewer) return;
    setSnapshot(previous => ({ ...previous, viewer, migrating: true, error: undefined }));
    try {
      const status = await (await loadPDSReadStateSync(oauth)).migrate();
      if (getOAuthSession() === oauth) setSnapshot(previous => ({ ...previous, viewer, status, migrating: false }));
    } catch (error) {
      if (getOAuthSession() === oauth) setSnapshot(previous => ({ ...previous, viewer, migrating: false,
        error: readStateErrorMessage(error) ?? "Migration is not complete. Existing read history remains protected. Please retry when the service is available." }));
    }
  }, [getOAuthSession, viewer]);
  return { enabled, ...(snapshot.viewer === viewer ? snapshot : {}), migrate };
}
