import type { OAuthSession } from "@atproto/oauth-client-browser";

export const USER_INPUT_BOARD_URL =
  "https://userinput.app/s/did:plc:qy5pluw2bsuq2x6albsgkvx3/3mrzw42so4j2h?lang=en";
export const USER_INPUT_BOARD_API_URL =
  "https://userinput.app/api/board/did:plc:qy5pluw2bsuq2x6albsgkvx3/3mrzw42so4j2h";
export const USER_INPUT_BOARD_URI =
  "at://did:plc:qy5pluw2bsuq2x6albsgkvx3/app.userinput.space/3mrzw42so4j2h";

export const USER_INPUT_DISCUSSION_COLLECTION = "app.userinput.discussion";
export const USER_INPUT_UPVOTE_COLLECTION = "app.userinput.upvote";

export const USER_INPUT_OAUTH_SCOPE = "include:app.userinput.authFull";
export const USER_INPUT_BLOB_OAUTH_SCOPE = "blob:*/*";
export const MAX_USER_INPUT_PHOTOS = 4;

export const USER_INPUT_REAUTH_MESSAGE =
  "Your session does not include feedback permissions yet. Sign out and sign back in, then try again.";

export interface UserInputTag {
  label: string;
  value: string;
}

export const LOCAL_USER_INPUT_TAGS: UserInputTag[] = [
  { label: "Bug", value: "bug" },
  { label: "Feature", value: "feature" },
  { label: "Question", value: "question" },
  { label: "Comment", value: "comment" },
];

export interface UserInputStrongRef {
  uri: string;
  cid: string;
}

export interface UserInputBoardReference extends UserInputStrongRef {
  tags: UserInputTag[];
}

interface UserInputBoardResponse {
  board?: {
    uri?: unknown;
    cid?: unknown;
    value?: {
      tags?: unknown;
    };
  };
}

type UserInputFetch = (input: string, init?: RequestInit) => Promise<Response>;

function scopeAllowsRepoAction(
  scopeToken: string,
  collection: string,
  action: "create" | "update"
): boolean {
  const [repoScope, query = ""] = scopeToken.split("?");
  if (repoScope !== `repo:${collection}`) return false;
  if (!query) return true;

  const params = new URLSearchParams(query);
  const actions = params.getAll("action");
  return actions.length === 0 || actions.includes(action);
}

function scopeName(scopeToken: string): string {
  return scopeToken.split("?", 1)[0] ?? scopeToken;
}

function scopeAllowsBlobMimeType(scopeToken: string, mimeType: string): boolean {
  const name = scopeName(scopeToken);
  if (!name.startsWith("blob:")) return false;

  const pattern = name.slice("blob:".length);
  const [patternType, patternSubtype] = pattern.split("/");
  const [mimeTypeType, mimeTypeSubtype] = mimeType.split("/");
  return (
    (patternType === "*" || patternType === mimeTypeType) &&
    (patternSubtype === "*" || patternSubtype === mimeTypeSubtype)
  );
}

export async function requireUserInputFeedbackScopes(
  session: Pick<OAuthSession, "getTokenInfo">,
  photoMimeTypes: readonly string[] = []
): Promise<void> {
  const info = await session.getTokenInfo("auto");
  const scopes = String(info.scope ?? "").split(/\s+/).filter(Boolean);
  const hasPermissionSet = scopes.some(
    (scope) => scopeName(scope) === USER_INPUT_OAUTH_SCOPE
  );
  const hasDiscussionCreate = scopes.some((scope) =>
    scopeAllowsRepoAction(scope, USER_INPUT_DISCUSSION_COLLECTION, "create")
  );
  const hasPhotoAccess = photoMimeTypes.every((mimeType) =>
    scopes.some((scope) => scopeAllowsBlobMimeType(scope, mimeType))
  );

  // The initial upvote is best-effort and must not prevent a discussion write.
  if ((!hasPermissionSet && !hasDiscussionCreate) || !hasPhotoAccess) {
    throw new Error(USER_INPUT_REAUTH_MESSAGE);
  }
}

export async function fetchUserInputBoardReference(
  fetcher: UserInputFetch = fetch
): Promise<UserInputBoardReference> {
  const response = await fetcher(USER_INPUT_BOARD_API_URL, {
    headers: { Accept: "application/json" },
    cache: "no-store",
  });
  if (!response.ok) {
    throw new Error(
      "The feedback board is unavailable right now. Try again shortly."
    );
  }

  const payload = (await response.json()) as UserInputBoardResponse;
  const uri = payload.board?.uri;
  const cid = payload.board?.cid;
  if (uri !== USER_INPUT_BOARD_URI || typeof cid !== "string" || !cid) {
    throw new Error("The feedback board returned an invalid response.");
  }

  const rawTags = payload.board?.value?.tags;
  const tags = Array.isArray(rawTags)
    ? rawTags.flatMap((tag) => {
        if (!tag || typeof tag !== "object") return [];
        const label = "label" in tag ? tag.label : undefined;
        const value = "value" in tag ? tag.value : undefined;
        return typeof label === "string" && typeof value === "string"
          ? [{ label, value }]
          : [];
      })
    : [];

  return { uri, cid, tags };
}

export function userInputDiscussionUrl(uri: string): string | null {
  const match = /^at:\/\/([^/]+)\/app\.userinput\.discussion\/([^/]+)$/.exec(
    uri
  );
  if (!match) return null;
  return `https://userinput.app/d/${encodeURIComponent(match[1])}/${encodeURIComponent(match[2])}?lang=en`;
}
