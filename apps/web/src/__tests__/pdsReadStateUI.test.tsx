import { afterEach, expect, spyOn, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import * as Status from "@/hooks/usePDSReadStateStatus";
import { PDSReadStateSettingsSection } from "@/components/Account/PDSReadStateSettingsSection";
import { PDSReadStateSyncNotice } from "@/components/Account/PDSReadStateSyncNotice";
let restore: (() => void) | undefined;
afterEach(() => { restore?.(); });
function snapshot(value: Partial<ReturnType<typeof Status.usePDSReadStateStatus>>) {
  const hook = spyOn(Status, "usePDSReadStateStatus").mockReturnValue({ enabled: true, migrate: async () => {}, ...value });
  restore = () => hook.mockRestore();
}
test("read-history migration is hidden until enabled and clearly describes public visibility before activation", () => {
  snapshot({ enabled: false });
  expect(renderToStaticMarkup(<PDSReadStateSettingsSection />)).toBe("");
  restore?.();
  snapshot({ status: { authority: "appview", migrationState: "notStarted", legacyRevision: 1 } });
  const markup = renderToStaticMarkup(<PDSReadStateSettingsSection />);
  expect(markup).toContain("Read and unread history is public on your PDS");
  expect(markup).toContain("Publish Read History to My PDS");
  expect(markup).toContain("includes your existing read and unread history");
});
test("pending and denied-access history remains visible without claiming synchronization succeeded", () => {
  snapshot({ status: { authority: "pds", migrationState: "verified", legacyRevision: 1 },
    outbox: { viewerDid: "did:plc:alice", lastError: "reauthorize", entries: [{ intent: { actionId: "pending", state: "unread", actedAt: "2026-09-08T00:00:00Z", selection: "exact", subjectUris: ["article"] }, attempts: 1, retryAt: 0 }] } });
  expect(renderToStaticMarkup(<PDSReadStateSyncNotice />)).toContain("Sign in again to synchronize");
  expect(renderToStaticMarkup(<PDSReadStateSettingsSection />)).toContain("1 change is waiting to sync");
  expect(renderToStaticMarkup(<PDSReadStateSettingsSection />)).toContain("Sign in again");
});

test("an unready projection remains visibly restoring with no pending writes", () => {
  snapshot({ status: { authority: "pds", migrationState: "verified", legacyRevision: 1, projectionReady: false },
    outbox: { viewerDid: "did:plc:alice", entries: [] } });
  const settings = renderToStaticMarkup(<PDSReadStateSettingsSection />);
  expect(settings).toContain("Restoring read history");
  expect(settings).not.toContain("Your PDS stores your read history.");
  expect(renderToStaticMarkup(<PDSReadStateSyncNotice />)).toContain("Restoring read history");
});
