import { afterEach, expect, it, spyOn } from "bun:test";
import { navigateTopicFeed } from "@/lib/topicFeedNavigation";

const restores: Array<() => void> = [];
afterEach(() => { for (const restore of restores.splice(0)) restore(); });

it.each(["sports", "finance"] as const)("changes %s selection through immediate client history and preserves the input", topic => {
  const history = spyOn(window.history, "pushState").mockImplementation(() => undefined);
  restores.push(() => history.mockRestore());
  const params = new URLSearchParams(`feed=${topic}&lang=en`);
  navigateTopicFeed(topic, "entity:opaque", params);
  const url = new URL(history.mock.calls[0][2]!.toString(), "https://example.test");
  expect(url.pathname).toBe("/read");
  expect(url.searchParams.get(`${topic}Feed`)).toBe("entity:opaque");
  expect(url.searchParams.get("lang")).toBe("en");
  expect(params.has(`${topic}Feed`)).toBe(false);
  navigateTopicFeed(topic, topic, url.searchParams);
  expect(new URL(history.mock.calls[1][2]!.toString(), "https://example.test").searchParams.has(`${topic}Feed`)).toBe(false);
});
