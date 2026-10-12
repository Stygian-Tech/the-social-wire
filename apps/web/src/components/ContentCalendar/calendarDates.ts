/** Calendar dates are local wall time; publishing timestamps are always UTC instants. */
export function localCalendarDate(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
export function localDateTimeValue(date: Date): string {
  return `${localCalendarDate(date)}T${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;
}
export function scheduledInstant(value: string, now = Date.now()): string | undefined {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(value)) return undefined;
  const date = new Date(value);
  // Reject browser-normalized invalid dates and nonexistent times across DST transitions.
  return Number.isFinite(date.getTime()) && localDateTimeValue(date) === value && date.getTime() >= now + 60_000 ? date.toISOString() : undefined;
}
export function calendarMonthDays(month: Date): Date[] {
  const first = new Date(month.getFullYear(), month.getMonth(), 1);
  const start = new Date(first.getFullYear(), first.getMonth(), 1 - first.getDay());
  return Array.from({ length: 42 }, (_, offset) => new Date(start.getFullYear(), start.getMonth(), start.getDate() + offset));
}
