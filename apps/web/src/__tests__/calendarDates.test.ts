import { expect, test } from "bun:test";
import { calendarMonthDays, localCalendarDate, localDateTimeValue, scheduledInstant } from "@/components/ContentCalendar/calendarDates";

test("projects local calendar dates and rejects invalid or too-soon publish times", () => {
  const now = new Date(2026, 9, 11, 12, 0);
  expect(localCalendarDate(now)).toBe("2026-10-11");
  expect(localDateTimeValue(now)).toBe("2026-10-11T12:00");
  expect(scheduledInstant("2026-10-11T12:01", now.getTime())).toBe(new Date(2026, 9, 11, 12, 1).toISOString());
  expect(scheduledInstant("2026-10-11T12:00", now.getTime())).toBeUndefined();
  expect(scheduledInstant("2026-02-30T12:00", now.getTime())).toBeUndefined();
  expect(scheduledInstant("2026-10-11T12:01Z", now.getTime())).toBeUndefined();
  expect(scheduledInstant("", now.getTime())).toBeUndefined();
});
test("builds a stable six-week month calendar without UTC date shifts", () => {
  const days = calendarMonthDays(new Date(2026, 1, 15));
  expect(days).toHaveLength(42);
  expect(days[0].getDay()).toBe(0);
  expect(localCalendarDate(days[0])).toBe("2026-02-01");
  expect(days.filter(day => day.getMonth() === 1)).toHaveLength(28);
  expect(localCalendarDate(days[41])).toBe("2026-03-14");
});
