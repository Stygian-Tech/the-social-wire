import { expect, it } from "bun:test";
import { ensureValidTid } from "@atproto/syntax";
import { podcastClipPostRkey } from "@/lib/podcasts/podcastClipPostRkey";

it("generates upstream-valid, stable TIDs within the immutable clip creation second", async () => {
  const createdAt = "2026-10-11T12:00:00Z";
  const key = await podcastClipPostRkey("did:plc:alice", "clip-1", createdAt);
  ensureValidTid(key);
  expect(await podcastClipPostRkey("did:plc:alice", "clip-1", createdAt)).toBe(key);
  const alphabet = "234567abcdefghijklmnopqrstuvwxyz";
  const value = [...key].reduce((value, char) => value * 32n + BigInt(alphabet.indexOf(char)), 0n);
  const microseconds = Number(value >> 10n);
  expect(Math.floor(microseconds / 1_000_000)).toBe(Date.parse(createdAt) / 1000);
  expect(await podcastClipPostRkey("did:plc:bob", "clip-1", createdAt)).not.toBe(key);
  const keys = await Promise.all(Array.from({ length: 100 }, (_, index) => podcastClipPostRkey("did:plc:alice", `clip-${index}`, createdAt)));
  expect(new Set(keys).size).toBe(keys.length);
  for (const key of keys) ensureValidTid(key);
});

it("rejects timestamps outside the TID range instead of wrapping into another key", async () => {
  for (const createdAt of ["invalid", "1969-12-31T23:59:59Z", "+010000-01-01T00:00:00Z"]) {
    await expect(podcastClipPostRkey("did:plc:alice", "clip-1", createdAt)).rejects.toThrow("creation time");
  }
});
