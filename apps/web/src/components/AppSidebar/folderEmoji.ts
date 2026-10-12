export const folderEmojiOptions = [
  { value: "📰", label: "Newspaper" },
  { value: "💻", label: "Computer" },
  { value: "🧪", label: "Science" },
  { value: "🎨", label: "Art" },
  { value: "🎧", label: "Audio" },
  { value: "📚", label: "Books" },
  { value: "🌍", label: "World" },
  { value: "🏠", label: "Home" },
  { value: "🚀", label: "Rocket" },
  { value: "⭐", label: "Star" },
  { value: "❤️", label: "Heart" },
  { value: "⚽", label: "Sports" },
  { value: "💰", label: "Finance" },
  { value: "🌱", label: "Nature" },
  { value: "🍿", label: "Entertainment" },
];

/** Keep joined, flag, skin-tone, and keycap emoji together as one glyph. */
export function isFolderEmoji(value: string): boolean {
  const trimmed = value.trim();
  const graphemes = [...new Intl.Segmenter(undefined, { granularity: "grapheme" }).segment(trimmed)];
  return graphemes.length === 1 && /\p{Extended_Pictographic}|\p{Regional_Indicator}|\p{Emoji_Presentation}|[0-9#*]\uFE0F?\u20E3/u.test(trimmed);
}
