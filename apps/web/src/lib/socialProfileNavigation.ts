import { safeSocialPostReturnPath } from "./socialPostNavigation";

export function isSocialProfileActor(value: string | null | undefined): value is string {
  return !!value && /^(?:did:[a-z]+:[^\s/?#\\]+|[a-z0-9](?:[a-z0-9.-]*\.[a-z0-9-]+))$/i.test(value);
}

export function socialProfilePageHref(actor: string, returnTo?: string): string {
  if (!isSocialProfileActor(actor)) throw new Error("This profile link is invalid.");
  return `/social/profile?${new URLSearchParams({ actor, returnTo: safeSocialPostReturnPath(returnTo) })}`;
}

/** Recognize profile links without mistaking post links or lookalike domains for profiles. */
export function socialProfileActorFromUrl(value: string): string | undefined {
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "bsky.app" || url.port || url.username || url.password) return undefined;
    const match = /^\/profile\/([^/]+)\/?$/.exec(url.pathname);
    if (!match) return undefined;
    const actor = decodeURIComponent(match[1]);
    return isSocialProfileActor(actor) ? actor : undefined;
  } catch { return undefined; }
}
