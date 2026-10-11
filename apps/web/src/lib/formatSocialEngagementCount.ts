/** Truncate compact counts so display never overstates engagement. */
export function formatSocialEngagementCount(value: number): string {
  const count = Number.isFinite(value) ? Math.max(0, Math.floor(value)) : 0;
  if (count < 1_000) return String(count);
  const [unit, suffix] = count >= 1_000_000_000 ? [1_000_000_000, "b"] : count >= 1_000_000 ? [1_000_000, "m"] : [1_000, "k"];
  const scaled = count / unit;
  const truncated = scaled < 10 ? Math.floor(count / (unit / 10)) / 10 : Math.floor(scaled);
  return `${truncated}${suffix}`;
}
