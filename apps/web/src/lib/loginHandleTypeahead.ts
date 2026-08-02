export const ACTOR_TYPEAHEAD_SERVICE_URL = "https://typeahead.waow.tech";

export interface LoginHandleSuggestion {
  did: string;
  handle: string;
  displayName?: string;
  avatar?: string;
}

export function loginHandleSearchQuery(value: string): string | null {
  const query = value.trim().replace(/^@/, "");
  if (
    query.length < 2 ||
    query.includes(":") ||
    query.includes("/") ||
    /\s/.test(query)
  ) {
    return null;
  }
  return query;
}

export async function searchLoginHandles(
  value: string,
  signal?: AbortSignal
): Promise<LoginHandleSuggestion[]> {
  const query = loginHandleSearchQuery(value);
  if (!query) return [];

  const url = new URL(
    "/xrpc/app.bsky.actor.searchActorsTypeahead",
    ACTOR_TYPEAHEAD_SERVICE_URL
  );
  url.searchParams.set("q", query);
  url.searchParams.set("limit", "6");
  const response = await fetch(url, { signal });
  if (!response.ok) {
    throw new Error(`Actor typeahead failed (${response.status})`);
  }
  const data = (await response.json()) as {
    actors?: LoginHandleSuggestion[];
  };
  return (data.actors ?? []).map((actor) => ({
    did: actor.did,
    handle: actor.handle,
    displayName: actor.displayName,
    avatar: actor.avatar,
  }));
}
