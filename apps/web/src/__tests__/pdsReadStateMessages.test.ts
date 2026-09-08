import { afterEach, expect, spyOn, test } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { ReadStateError } from "@thesocialwire/read-state";
import * as Transport from "@/lib/socialWireGatewayClient";
import { PDSReadStateGateway } from "@/lib/pdsReadStateGateway";
import { READ_STATE_RESTORING_MESSAGE, READ_STATE_SCOPE_CONFLICT_MESSAGE, readStateErrorMessage, readStateStatusMessage } from "@/lib/pdsReadStateMessages";

let restore: (() => void) | undefined;
afterEach(() => restore?.());
function gateway(status: number, body: unknown) {
  const fetch = spyOn(Transport, "gatewayFetch").mockResolvedValue(Response.json(body, { status }));
  restore = () => fetch.mockRestore();
  return new PDSReadStateGateway({ did: "did:plc:viewer" } as unknown as OAuthSession, () => {});
}

test("scope overlap retains an actionable typed conflict without suggesting reauthorization", async () => {
  try { await gateway(409, { error: "ReadStateMigrationScopeConflict" }).exportPage(); throw new Error("Expected failure"); }
  catch (error) {
    expect(error).toBeInstanceOf(ReadStateError);
    expect((error as ReadStateError).code).toBe("migration_scope_conflict");
    expect(readStateErrorMessage(error)).toBe(READ_STATE_SCOPE_CONFLICT_MESSAGE);
    expect(readStateErrorMessage(error)).toContain("Mark All As Read");
    expect(readStateErrorMessage(error)).not.toContain("Sign in");
  }
});
test("projection readiness is distinguished from unrelated 503 and CAS conflicts", async () => {
  await expect(gateway(503, { error: "ReadStateNotReady" }).status()).rejects.toThrow(READ_STATE_RESTORING_MESSAGE);
  restore?.();
  await expect(gateway(409, { error: "DifferentConflict" }).exportPage()).rejects.toMatchObject({ code: "conflict" });
  restore?.();
  await expect(gateway(503, { error: "DifferentUnavailable" }).status()).rejects.toMatchObject({ status: 503 });
});
test("persisted denied access and readiness survive an empty queue/status refresh", () => {
  const status = { authority: "pds" as const, migrationState: "verified" as const, legacyRevision: 1, projectionReady: false };
  expect(readStateStatusMessage(status, { viewerDid: "did:plc:viewer", entries: [] })).toBe(READ_STATE_RESTORING_MESSAGE);
  expect(readStateStatusMessage(status, { viewerDid: "did:plc:viewer", entries: [], lastError: "reauthorize" })).toContain("Sign in again");
  expect(readStateStatusMessage({ ...status, projectionReady: true })).toBeUndefined();
  expect(readStateErrorMessage("unavailable")).toContain("pending changes");
});
