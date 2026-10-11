export type MentionRange = { start: number; end: number; query: string };

/** Only the token at the caret triggers lookup; email addresses and URL paths do not. */
export function socialMentionAtCaret(text: string, caret: number): MentionRange | undefined {
  const prefix = text.slice(0, caret);
  const match = /(?:^|[\s(])@([a-zA-Z0-9.-]*)$/.exec(prefix);
  if (!match) return undefined;
  const start = caret - match[1].length - 1;
  let end = caret;
  while (/[a-zA-Z0-9.-]/.test(text[end] ?? "") && end < text.length) end++;
  return { start, end, query: match[1] };
}

export function insertSocialMention(text: string, range: MentionRange, handle: string) {
  const mention = `@${handle}${/^\s/.test(text.slice(range.end)) ? "" : " "}`;
  return { text: text.slice(0, range.start) + mention + text.slice(range.end), caret: range.start + mention.length };
}
