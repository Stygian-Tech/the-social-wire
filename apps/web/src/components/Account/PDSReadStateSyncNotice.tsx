"use client";

import { readStateStatusMessage } from "@/lib/pdsReadStateMessages";
import Link from "next/link";
import { usePDSReadStateStatus } from "@/hooks/usePDSReadStateStatus";

export function PDSReadStateSyncNotice() {
  const { enabled, status, outbox, error } = usePDSReadStateStatus();
  const message = error ?? readStateStatusMessage(status, outbox);
  if (!enabled || (!message && !outbox?.entries.length)) return null;
  return <aside role="status" className="fixed bottom-4 right-4 z-50 max-w-sm rounded-xl border bg-background p-3 text-sm shadow-md">
    <p>{message ?? (outbox?.lastError === "reauthorize" ? "Sign in again to synchronize your public read history."
      : `${outbox?.entries.length ?? 0} read-history ${outbox?.entries.length === 1 ? "change" : "changes"} saved on this device and waiting to sync.`)}</p>
    {status?.authority === "pds" && <Link className="mt-1 inline-block underline" href="/me#read-history">Read History Settings</Link>}
  </aside>;
}
