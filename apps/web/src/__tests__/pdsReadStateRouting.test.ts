import { afterEach, expect, spyOn, test } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import * as Sync from "@/lib/pdsReadStateSync";
import * as Gateway from "@/lib/socialWireGatewayClient";
import { writeThroughReadMark, writeThroughReadMarkDelete } from "@/lib/thinAppViewClient";
import { markAllReadOnGateway } from "@/lib/publicationProjectionClient";
import { markReadBefore } from "@/lib/feedReadAgeClient";

const oauth = { did: "did:plc:viewer" } as unknown as OAuthSession;
const cleanup: (() => void)[] = [];
afterEach(() => { cleanup.splice(0).forEach(restore => restore()); });
function configure(canonical: boolean) {
  const authority = spyOn(Sync, "usesPDSReadState").mockResolvedValue(canonical);
  const gateway = spyOn(Gateway, "gatewayFetch").mockResolvedValue(Response.json({}));
  cleanup.push(() => authority.mockRestore(), () => gateway.mockRestore());
  return { authority, gateway };
}
test("canonical individual read and unread enqueue on the PDS runtime without legacy writes", async () => {
  const { gateway } = configure(true); const writes: unknown[][] = [];
  const runtime = spyOn(Sync, "pdsReadStateSync").mockReturnValue({ exact: async (...args: unknown[]) => { writes.push(args); } } as unknown as Sync.PDSReadStateSync);
  cleanup.push(() => runtime.mockRestore());
  await writeThroughReadMark(oauth, "article", "2026-09-08T00:00:00Z");
  await writeThroughReadMarkDelete(oauth, "article");
  expect(writes).toEqual([[["article"], "read", "2026-09-08T00:00:00Z"], [["article"], "unread"]]);
  expect(gateway).not.toHaveBeenCalled();
});
test("canonical bulk and calendar actions preserve frozen selection and report pending rather than server counts", async () => {
  const { gateway } = configure(true); const calls: unknown[][] = [];
  const runtime = spyOn(Sync, "pdsReadStateSync").mockReturnValue({ bulk: async (...args: unknown[]) => {
    calls.push(args); return { actedAt: "2026-09-08T12:00:00Z", selection: "exact", subjectUris: ["old-story"], legacyRevision: 1 };
  } } as unknown as Sync.PDSReadStateSync);
  cleanup.push(() => runtime.mockRestore());
  expect(await markAllReadOnGateway(oauth, { kind: "subscribed" })).toMatchObject({ pendingSync: true, unreadCounts: {} });
  expect(await markReadBefore(oauth, { kind: "following" }, "2026-09-07T05:00:00Z", { timeZone: "America/Chicago", referenceDate: "2026-09-08" }))
    .toMatchObject({ pendingSync: true, entryIds: ["old-story"], unreadCounts: {} });
  expect(calls[1]).toEqual([{ kind: "following" }, { before: "2026-09-07T05:00:00Z", timeZone: "America/Chicago", referenceDate: "2026-09-08" }]);
  expect(gateway).not.toHaveBeenCalled();
});
test("an unactivated account keeps the existing mutation path and unavailable authority never falls back", async () => {
  const { authority, gateway } = configure(false);
  await writeThroughReadMark(oauth, "article", "2026-09-08T00:00:00Z");
  expect(gateway).toHaveBeenCalledTimes(1);
  authority.mockRejectedValue(new Error("Unavailable"));
  await expect(writeThroughReadMarkDelete(oauth, "article")).rejects.toThrow("Unavailable");
  expect(gateway).toHaveBeenCalledTimes(1);
});
