"use client";

import { READ_STATE_RESTORING_MESSAGE, readStateStatusMessage } from "@/lib/pdsReadStateMessages";
import { Button } from "@/components/ui/button";
import { usePDSReadStateStatus } from "@/hooks/usePDSReadStateStatus";
import { PDS_READ_HISTORY_NOTICE } from "@/lib/pdsReadStateSync";

export function PDSReadStateSettingsSection() {
  const { enabled, status, outbox, error, migrating, migrate } = usePDSReadStateStatus();
  if (!enabled) return null;
  const message = error ?? readStateStatusMessage(status, outbox);
  return <section id="read-history" className="rounded-2xl border bg-card p-4">
    <h2 className="text-sm font-bold">Public Read History</h2>
    <p className="mt-2 text-sm text-muted-foreground">{PDS_READ_HISTORY_NOTICE}</p>
    {status?.authority === "pds" ? <p className="mt-2 text-sm">{outbox?.entries.length
      ? `${outbox.entries.length} ${outbox.entries.length === 1 ? "change is" : "changes are"} waiting to sync.` : status.projectionReady === false ? READ_STATE_RESTORING_MESSAGE : "Your PDS stores your read history."}</p>
      : <><p className="mt-2 text-sm text-muted-foreground">Publishing includes your existing read and unread history. Migration is verified before your PDS becomes authoritative.</p>
        <Button className="mt-3" disabled={!status || migrating} onClick={() => { void migrate(); }}>
          {migrating ? "Publishing Read History…" : "Publish Read History to My PDS"}
        </Button></>}
    {message && !(message === READ_STATE_RESTORING_MESSAGE && !outbox?.entries.length && status?.authority === "pds")
      && <p role="alert" className="mt-2 text-sm text-destructive">{message}</p>}
  </section>;
}
