import { lexicons, type AppBskyDraftDefs } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { createAuthenticatedAppViewAgent } from "@/lib/blueskySocialClient";

type DraftActor = {
  session: OAuthSession;
  viewerDid: string;
  signal?: AbortSignal;
  assertCurrentActor?: () => void;
};

function guard(args: DraftActor): void {
  args.signal?.throwIfAborted();
  if (!args.viewerDid || args.session.did !== args.viewerDid) {
    throw new Error("Your account changed. Please reload your drafts.");
  }
  args.assertCurrentActor?.();
}

/** Recheck even failed requests so stale actors cannot drive caller recovery. */
async function request<T>(args: DraftActor, send: () => Promise<T>): Promise<T> {
  guard(args);
  try {
    return await send();
  } finally {
    guard(args);
  }
}

function validateInput(method: string, payload: unknown): void {
  // Validate the original object; rebuilding known fields would lose future SDK data.
  lexicons.assertValidXrpcInput(`app.bsky.draft.${method}`, payload);
}

function validateId(id: string): void {
  // createDraft's output only declares a string; deleteDraft declares the TID format.
  validateInput("deleteDraft", { id });
}

/** Private AppView stash only. No repo records, public fallback, or mutation retries. */
export async function listSocialDrafts(args: DraftActor & { cursor?: string }): Promise<{ drafts: AppBskyDraftDefs.DraftView[]; cursor?: string }> {
  guard(args);
  const params = { limit: 100, ...(args.cursor === undefined ? {} : { cursor: args.cursor }) };
  lexicons.assertValidXrpcParams("app.bsky.draft.getDrafts", params);
  const agent = createAuthenticatedAppViewAgent(args.session);
  const response = await request(args, () => agent.app.bsky.draft.getDrafts(params, { signal: args.signal }));
  guard(args);
  lexicons.assertValidXrpcOutput("app.bsky.draft.getDrafts", response.data);
  if (response.data.drafts.length > 100) throw new Error("The draft page exceeds the requested limit.");
  return response.data;
}

export async function createSocialDraft(args: DraftActor & { draft: AppBskyDraftDefs.Draft }): Promise<{ id: string }> {
  guard(args);
  const payload = { draft: args.draft };
  validateInput("createDraft", payload);
  const agent = createAuthenticatedAppViewAgent(args.session);
  const response = await request(args, () => agent.app.bsky.draft.createDraft(payload, { signal: args.signal }));
  guard(args);
  lexicons.assertValidXrpcOutput("app.bsky.draft.createDraft", response.data);
  validateId(response.data.id);
  return response.data;
}

export async function updateSocialDraft(args: DraftActor & { id: string; draft: AppBskyDraftDefs.Draft }): Promise<void> {
  guard(args);
  const payload = { draft: { id: args.id, draft: args.draft } };
  validateInput("updateDraft", payload);
  const agent = createAuthenticatedAppViewAgent(args.session);
  await request(args, () => agent.app.bsky.draft.updateDraft(payload, { signal: args.signal }));
  guard(args);
}

export async function deleteSocialDraft(args: DraftActor & { id: string }): Promise<void> {
  guard(args);
  const payload = { id: args.id };
  validateInput("deleteDraft", payload);
  const agent = createAuthenticatedAppViewAgent(args.session);
  await request(args, () => agent.app.bsky.draft.deleteDraft(payload, { signal: args.signal }));
  guard(args);
}
