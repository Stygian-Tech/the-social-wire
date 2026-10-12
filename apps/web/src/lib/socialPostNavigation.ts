/** Only app-owned destinations may be carried into a post's Back action. */
export function safeSocialPostReturnPath(value: string | null | undefined): string {
  if (!value || !value.startsWith("/") || value.startsWith("//") || /[\\\u0000-\u001f]/.test(value)) return "/social";
  try {
    const url = new URL(value, "https://socialwire.invalid");
    if (url.origin !== "https://socialwire.invalid" || !["/social", "/social/explore", "/social/notifications", "/social/bookmarks", "/social/lists", "/social/feeds", "/social/profile", "/social/messages", "/me", "/live-post"].includes(url.pathname)) return "/social";
    return url.pathname + url.search + url.hash;
  } catch { return "/social"; }
}

export function isSocialPostUri(value: string | null | undefined): value is string {
  return !!value && /^at:\/\/did:[^\s/?#]+\/app\.bsky\.feed\.post\/[^\s/?#]+$/.test(value);
}

export function socialPostPageHref(uri: string, returnTo?: string): string {
  if (!isSocialPostUri(uri)) throw new Error("This post link is invalid.");
  return `/social/post?${new URLSearchParams({ uri, returnTo: safeSocialPostReturnPath(returnTo) })}`;
}
