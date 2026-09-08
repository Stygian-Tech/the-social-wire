import { afterEach, expect, spyOn, test } from "bun:test";
import { QueryClient } from "@tanstack/react-query";
import { cleanup, renderHook, waitFor, act } from "@testing-library/react";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { OutboxState } from "@thesocialwire/read-state";
import * as Auth from "@/hooks/useAuth";
import * as Sync from "@/lib/pdsReadStateSync";
import { usePendingPDSReadState } from "@/hooks/usePendingPDSReadState";
import { effectiveEntryReadState, pendingReadStateOverlay, invalidateConfirmedReadStateQueries } from "@/lib/pendingReadStateOverlay";
const restores: (() => void)[] = [];
afterEach(() => { cleanup(); restores.splice(0).forEach(restore => restore()); });
const alice = { did: "did:plc:alice" } as unknown as OAuthSession;
const bob = { did: "did:plc:bob" } as unknown as OAuthSession;
function snapshot(did: string): OutboxState {
  return { viewerDid: did, entries: [{ attempts: 1, retryAt: 9999999999999,
    intent: { actionId: "unread", state: "unread", actedAt: "2026-09-08T00:00:00Z", selection: "exact", subjectUris: ["article"] } }] };
}
function fixture(read: (oauth: OAuthSession) => Promise<OutboxState>) {
  let oauth = alice;
  const getOAuthSession = () => oauth;
  const auth = spyOn(Auth, "useAuth").mockImplementation(() => ({ session: { did: oauth.did }, getOAuthSession, oauthSessionReloadSeq: 0 } as ReturnType<typeof Auth.useAuth>));
  const enabled = spyOn(Sync, "pdsReadStateEnabled").mockReturnValue(true);
  const runtime = spyOn(Sync, "pdsReadStateSync").mockImplementation(value => ({ snapshot: () => read(value) } as Sync.PDSReadStateSync));
  restores.push(() => auth.mockRestore(), () => enabled.mockRestore(), () => runtime.mockRestore());
  return { switchAccount: () => { oauth = bob; } };
}
test("restart, foreground, and refreshed server flags preserve pending unread until confirmation", async () => {
  let durable = snapshot(alice.did);
  fixture(async () => structuredClone(durable));
  const first = renderHook(usePendingPDSReadState);
  await waitFor(() => expect(first.result.current.get("article")).toBe(false));
  first.unmount();
  const restarted = renderHook(usePendingPDSReadState);
  await waitFor(() => expect(restarted.result.current.get("article")).toBe(false));
  restarted.rerender();
  expect(effectiveEntryReadState("article", true, () => true, id => restarted.result.current.get(id))).toBe(false);
  act(() => document.dispatchEvent(new window.Event("visibilitychange")));
  expect(effectiveEntryReadState("article", true, () => false, id => restarted.result.current.get(id))).toBe(false);
  durable = { viewerDid: alice.did, entries: [] };
  act(() => window.dispatchEvent(new window.CustomEvent(Sync.PDS_READ_STATE_SYNC_EVENT, { detail: { viewerDid: alice.did, kind: "confirmed" } })));
  await waitFor(() => expect(restarted.result.current.has("article")).toBe(false));
  expect(effectiveEntryReadState("article", true, () => false, id => restarted.result.current.get(id))).toBe(true);
});
test("account change discards a late old-viewer snapshot and never displays its pending state", async () => {
  let finishAlice: ((value: OutboxState) => void) | undefined;
  const env = fixture(oauth => oauth.did === alice.did ? new Promise(resolve => { finishAlice = resolve; }) : Promise.resolve({ viewerDid: bob.did, entries: [] }));
  const hook = renderHook(usePendingPDSReadState);
  env.switchAccount(); hook.rerender();
  await act(async () => { finishAlice?.(snapshot(alice.did)); });
  expect(hook.result.current.size).toBe(0);
});
test("boundary previews use only server-validated IDs, with later exact actions taking precedence", () => {
  const pending = snapshot(alice.did);
  pending.entries.unshift({ attempts: 0, retryAt: 0, previewSubjectUris: ["article", "confirmed-scope"],
    intent: { actionId: "boundary", state: "read", actedAt: "2026-09-08T00:00:00Z", selection: "boundaries",
      boundaries: [{ scope: { publicationId: "publication", authorDid: "did:plc:author", publicationSiteKeys: [] }, createdAt: "2026-09-08T00:00:00Z" }] } });
  const overlay = pendingReadStateOverlay(pending, alice.did);
  expect(overlay.get("article")).toBe(false);
  expect(overlay.get("confirmed-scope")).toBe(true);
  expect(overlay.has("later-arrival")).toBe(false);
  expect(pendingReadStateOverlay(pending, bob.did).size).toBe(0);
});

test("confirmation discards stale inactive unread feeds without touching another viewer", async () => {
  const client = new QueryClient();
  const unread = ["entries", alice.did, "publication", "unread"];
  const all = ["entries", alice.did, "publication", "all"];
  const other = ["entries", bob.did, "publication", "unread"];
  for (const key of [unread, all, other]) client.setQueryData(key, { rows: ["article"] });
  await invalidateConfirmedReadStateQueries(client, alice.did);
  expect(client.getQueryData(unread)).toBeUndefined();
  expect(client.getQueryState(all)?.isInvalidated).toBe(true);
  expect(client.getQueryState(other)?.isInvalidated).toBe(false);
  expect(client.getQueryData<unknown>(other)).toEqual({ rows: ["article"] });
});
