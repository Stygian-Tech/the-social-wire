import { createPublicAppViewAgent } from "@/lib/atprotoClient";

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
    query.startsWith("did:") ||
    /\s/.test(query)
  ) {
    return null;
  }
  return query;
}

export async function searchLoginHandles(
  value: string
): Promise<LoginHandleSuggestion[]> {
  const query = loginHandleSearchQuery(value);
  if (!query) return [];

  const response =
    await createPublicAppViewAgent().api.app.bsky.actor.searchActorsTypeahead({
      q: query,
      limit: 6,
    });
  return response.data.actors.map((actor) => ({
    did: actor.did,
    handle: actor.handle,
    displayName: actor.displayName,
    avatar: actor.avatar,
  }));
}
