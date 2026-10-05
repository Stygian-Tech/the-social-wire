import { afterEach, expect, it, spyOn } from "bun:test";
import { acknowledgeSportsPublicInterests, readSportsPublicInterestConsent, sportsPublicInterestConsentStorageKey } from "@/lib/sportsPublicInterestConsent";

const restores: (() => void)[] = [];
afterEach(() => { for (const restore of restores.splice(0)) restore(); window.localStorage.clear(); });

it("records explicit acknowledgement in a versioned browser record scoped to the viewer", () => {
  const did = "did:plc:consent-storage-viewer";
  expect(readSportsPublicInterestConsent(did)).toBe(false);
  acknowledgeSportsPublicInterests(did);
  const record = JSON.parse(window.localStorage.getItem(sportsPublicInterestConsentStorageKey(did))!);
  expect(record.version).toBe(1);
  expect(record.acknowledgedAt).toBeGreaterThan(0);
  expect(record.acknowledgedAt).toBeLessThanOrEqual(Date.now());
  expect(readSportsPublicInterestConsent(did)).toBe(true);
  expect(readSportsPublicInterestConsent("did:plc:consent-storage-other")).toBe(false);
});

it("restores valid persisted acknowledgement but rejects malformed, old, and future records", () => {
  const records = ["bad json", "null", "true", JSON.stringify({ version: 0, acknowledgedAt: Date.now() }), JSON.stringify({ version: 1, acknowledgedAt: "yesterday" }), JSON.stringify({ version: 1, acknowledgedAt: 0 }), JSON.stringify({ version: 1, acknowledgedAt: Date.now() + 100_000 })];
  records.forEach((record, index) => {
    const did = `did:plc:consent-invalid-${index}`;
    window.localStorage.setItem(sportsPublicInterestConsentStorageKey(did), record);
    expect(readSportsPublicInterestConsent(did)).toBe(false);
  });
  const did = "did:plc:consent-restored";
  window.localStorage.setItem(sportsPublicInterestConsentStorageKey(did), JSON.stringify({ version: 1, acknowledgedAt: Date.now() - 1_000 }));
  expect(readSportsPublicInterestConsent(did)).toBe(true);
});

it("retains explicit consent only for the current viewer when storage is blocked", () => {
  const prototype = Object.getPrototypeOf(window.localStorage) as Storage;
  const get = spyOn(prototype, "getItem").mockImplementation(() => { throw new Error("Storage Blocked"); });
  const set = spyOn(prototype, "setItem").mockImplementation(() => { throw new Error("Storage Blocked"); });
  restores.push(() => get.mockRestore(), () => set.mockRestore());
  const did = "did:plc:consent-blocked";
  expect(readSportsPublicInterestConsent(did)).toBe(false);
  acknowledgeSportsPublicInterests(did);
  expect(readSportsPublicInterestConsent(did)).toBe(true);
  expect(readSportsPublicInterestConsent("did:plc:consent-blocked-other")).toBe(false);
});

it("does not record acknowledgement without a viewer identity", () => {
  acknowledgeSportsPublicInterests(undefined);
  expect(readSportsPublicInterestConsent(undefined)).toBe(false);
  expect(window.localStorage.length).toBe(0);
});
