import { safeSocialPostReturnPath } from "./socialPostNavigation";

export function isSocialProfileActor(value: string | null | undefined): value is string {
  return !!value && /^(?:did:[a-z]+:[^\s/?#\\]+|[a-z0-9](?:[a-z0-9.-]*\.[a-z0-9-]+))$/i.test(value);
}

export function socialProfilePageHref(actor: string, returnTo?: string): string {
  if (!isSocialProfileActor(actor)) throw new Error("This profile link is invalid.");
  return `/social/profile?${new URLSearchParams({ actor, returnTo: safeSocialPostReturnPath(returnTo) })}`;
}
