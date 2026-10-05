import type { OAuthSession } from "@atproto/oauth-client-browser";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export type StandardReaderListPublication = {
  publicationId: string;
  title: string;
  authorDid: string;
  authorHandle?: string;
  iconUrl?: string;
  avatarUrl?: string;
};

export type StandardReaderList = {
  uri: string;
  name: string;
  description?: string;
  creatorDid: string;
  publications: string[];
  publicationDetails?: StandardReaderListPublication[];
  users: string[];
  owned: boolean;
  saved: boolean;
};
export type StandardReaderListsPage = {
  lists: StandardReaderList[];
  refreshedAt: string;
  creatorDid?: string;
  complete?: boolean;
};
export const standardReaderListsQueryKey = (viewer: string, revision = 0) =>
  ["standardReaderLists", viewer, revision] as const;
async function request<T>(
  oauth: OAuthSession,
  path: string,
  body?: unknown,
  signal?: AbortSignal,
): Promise<T> {
  const response = await gatewayFetch(oauth, path, {
    method: body === undefined ? "GET" : "POST",
    signal,
    ...(body === undefined
      ? {}
      : {
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }),
  });
  if (!response.ok) {
    let message = `Lists could not load (${response.status})`;
    try {
      const error = (await response.json()) as {
        message?: unknown;
        error?: { message?: unknown };
      };
      const detail = error.message ?? error.error?.message;
      if (typeof detail === "string" && detail.trim()) message = detail;
    } catch {
      /* Preserve the status when no error envelope is available. */
    }
    throw new Error(message);
  }
  return response.json() as Promise<T>;
}
export const getStandardReaderLists = (
  oauth: OAuthSession,
  signal?: AbortSignal,
) => request<StandardReaderListsPage>(oauth, "/v1/lists", undefined, signal);
export const searchStandardReaderLists = (
  oauth: OAuthSession,
  creator: string,
  signal?: AbortSignal,
) =>
  request<StandardReaderListsPage>(
    oauth,
    `/v1/lists/search?${new URLSearchParams({ creator })}`,
    undefined,
    signal,
  );
export const resolveStandardReaderList = async (
  oauth: OAuthSession,
  input: string,
  signal?: AbortSignal,
) =>
  (
    await request<{ list: StandardReaderList }>(
      oauth,
      "/v1/lists/resolve",
      { input },
      signal,
    )
  ).list;
export const refreshStandardReaderLists = (
  oauth: OAuthSession,
  signal?: AbortSignal,
) => request<StandardReaderListsPage>(oauth, "/v1/lists/refresh", {}, signal);

export function mergeStandardReaderListsPage(
  previous: StandardReaderListsPage | undefined,
  incoming: StandardReaderListsPage,
): StandardReaderListsPage {
  if (incoming.complete !== false || !previous) return incoming;
  const lists = new Map(previous.lists.map((list) => [list.uri, list]));
  for (const list of incoming.lists) lists.set(list.uri, list);
  return { ...incoming, lists: [...lists.values()] };
}
