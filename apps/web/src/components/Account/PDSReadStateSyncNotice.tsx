"use client";

import Link from "next/link";
import { usePDSReadStateStatus } from "@/hooks/usePDSReadStateStatus";

export function PDSReadStateSyncNotice() {
  const { enabled, status, outbox, error } = usePDSReadStateStatus();
  if (!enabled || (!error && !outbox?.entries.length)) return null;
  return <aside role="status" className="fixed bottom-4 right-4 z-50 max-w-sm rounded-xl border bg-background p-3 text-sm shadow-md">
    <p>{error ?? (outbox?.lastError === "reauthorize" ? "Sign in again to synchronize your public read history."
      : `${outbox?.entries.length ?? 0} read-history ${outbox?.entries.length === 1 ? "change" : "changes"} saved on this device and waiting to sync.`)}</p>
    {status?.authority === "pds" && <Link className="mt-1 inline-block underline" href="/me#read-history">Read History Settings</Link>}
  </aside>;
}
