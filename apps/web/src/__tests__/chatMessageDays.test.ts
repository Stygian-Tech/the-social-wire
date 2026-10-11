import { describe, expect, it } from "bun:test";
import { chatMessageDays } from "@/lib/chatMessageDays";
const now = new Date(2026, 9, 10, 12);
const message = (day: number, hour = 12) => ({ sentAt: new Date(2026, 9, day, hour).toISOString() });
describe("chat calendar-day separators", () => {
  it("labels local Today and Yesterday once per chronological day", () => {
    expect(chatMessageDays([message(9, 0), message(9, 23), message(10, 0), message(10, 23)], now)).toEqual(["Yesterday", undefined, "Today", undefined]);
  });
  it("keeps one separator when older pages prepend messages from the same day", () => {
    expect(chatMessageDays([message(9, 1), message(9, 2), message(9, 3), message(10)], now)).toEqual(["Yesterday", undefined, undefined, "Today"]);
  });
  it("does not introduce duplicates around an invalid timestamp", () => {
    expect(chatMessageDays([message(10), { sentAt: "invalid" }, message(10, 13)], now)).toEqual(["Today", undefined, undefined]);
  });
  it("includes the year for older years and handles deleted messages by their timestamp", () => {
    const date = new Date(2025, 11, 31, 12);
    const deleted = { sentAt: date.toISOString(), $type: "chat.bsky.convo.defs#deletedMessageView" };
    expect(chatMessageDays([deleted], now)).toEqual([date.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric", year: "numeric" })]);
  });
});
