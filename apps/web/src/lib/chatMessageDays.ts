/** Date labels follow the viewer's calendar, including daylight-saving boundaries. */
export function chatMessageDays(messages: readonly { sentAt: string }[], now = new Date()): (string | undefined)[] {
  const key = (date: Date) => `${date.getFullYear()}-${date.getMonth()}-${date.getDate()}`;
  const today = key(now);
  const yesterday = new Date(now);
  yesterday.setDate(yesterday.getDate() - 1);
  let previousDay: string | undefined;
  return messages.map(message => {
    const date = new Date(message.sentAt);
    if (Number.isNaN(date.getTime())) return undefined;
    const day = key(date);
    if (day === previousDay) return undefined;
    previousDay = day;
    if (day === today) return "Today";
    if (day === key(yesterday)) return "Yesterday";
    return date.toLocaleDateString(undefined, { weekday: "long", month: "short", day: "numeric", ...(date.getFullYear() !== now.getFullYear() ? { year: "numeric" } as const : {}) });
  });
}
