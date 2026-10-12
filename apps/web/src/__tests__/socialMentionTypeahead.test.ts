import { describe, expect, it } from "bun:test";
import { insertSocialMention, socialMentionAtCaret } from "@/lib/socialMentionTypeahead";
describe("mention tokens", () => {
  it("recognizes handles at the caret and excludes emails and URL paths", () => {
    expect(socialMentionAtCaret("Hi @alice", 9)).toEqual({ start: 3, end: 9, query: "alice" });
    expect(socialMentionAtCaret("mail@alice.test", 15)).toBeUndefined();
    expect(socialMentionAtCaret("https://test/@alice", 18)).toBeUndefined();
    expect(socialMentionAtCaret("Hi @", 4)?.query).toBe("");
  });
  it("replaces the complete token while retaining surrounding text and Unicode", () => {
    const text = "😊 @alzzz later";
    const range = socialMentionAtCaret(text, 6)!;
    expect(insertSocialMention(text, range, "alice.test")).toEqual({ text: "😊 @alice.test later", caret: 14 });
  });
});
