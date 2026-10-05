/** Topic changes stay on the client-owned /read page. Next synchronizes native history with useSearchParams. */
export function navigateTopicFeed(topic: "sports" | "finance", id: string, current: { toString(): string }) {
  const next = new URLSearchParams(current.toString());
  next.set("feed", topic);
  const key = topic === "sports" ? "sportsFeed" : "financeFeed";
  if (id === topic) next.delete(key);
  else next.set(key, id);
  window.history.pushState(null, "", `/read?${next.toString()}`);
}
