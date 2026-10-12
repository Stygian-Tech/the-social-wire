const TID_ALPHABET = "234567abcdefghijklmnopqrstuvwxyz";

/** Stable retry key with a real timestamp, not an arbitrary hash-shaped TID. */
export async function podcastClipPostRkey(did: string, clipId: string, createdAt: string): Promise<string> {
  const milliseconds = Date.parse(createdAt);
  const second = Math.floor(milliseconds / 1000);
  if (!did || !clipId || !Number.isFinite(milliseconds) || second < 0) throw new Error("The clip has an invalid creation time.");
  const digest = new DataView(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${did}\n${clipId}`)));
  // Hosted clips have second precision. Spread same-second clips across its
  // microseconds and clock IDs without moving their keys into another second.
  const microseconds = second * 1_000_000 + digest.getUint32(0) % 1_000_000;
  if (!Number.isSafeInteger(microseconds)) throw new Error("The clip has an invalid creation time.");
  let value = (BigInt(microseconds) << 10n) | BigInt(digest.getUint16(4) & 1023);
  let key = "";
  for (let index = 0; index < 13; index++) {
    key = TID_ALPHABET[Number(value & 31n)] + key;
    value >>= 5n;
  }
  return key;
}
