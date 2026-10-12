const UNITS = [
  { seconds: 31_536_000, suffix: "y" },
  { seconds: 2_592_000, suffix: "mo" },
  { seconds: 86_400, suffix: "d" },
  { seconds: 3_600, suffix: "h" },
  { seconds: 60, suffix: "m" },
  { seconds: 1, suffix: "s" },
];

export function socialRelativeTime(timestamp: number, now = Date.now()): string {
  if (!Number.isFinite(timestamp)) return "";
  const elapsed = Math.max(0, Math.floor((now - timestamp) / 1_000));
  const unit = UNITS.find(unit => elapsed >= unit.seconds) ?? UNITS[UNITS.length - 1]!;
  return `${Math.floor(elapsed / unit.seconds)}${unit.suffix}`;
}
