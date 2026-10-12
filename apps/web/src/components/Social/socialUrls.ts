/** Remote content may only navigate or load over HTTPS. */
export function socialHttpsUrl(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username || url.password)
      return undefined;
    return url.href;
  } catch {
    return undefined;
  }
}

export function socialProfileUrl(did: string): string {
  return `https://bsky.app/profile/${encodeURIComponent(did)}`;
}

export function socialPostUrl(uri: string): string | undefined {
  const match = /^at:\/\/(did:[^/]+)\/app\.bsky\.feed\.post\/([^/]+)$/.exec(
    uri,
  );
  return match
    ? `${socialProfileUrl(match[1])}/post/${encodeURIComponent(match[2])}`
    : undefined;
}
