import { Agent } from "@atproto/api";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { PDSRequestError, ReadStateError, type Chunk, type Manifest,
  type ReadStateRepository, type RepositoryRecord } from "@thesocialwire/read-state";

function repositoryError(error: unknown): never {
  const failure = error as { status?: number; error?: string; headers?: Record<string, string> };
  if (failure.error === "InvalidSwap") throw new ReadStateError("conflict");
  if (failure.status === 401 || failure.status === 403) throw new ReadStateError("reauthorize");
  if (failure.status) throw new PDSRequestError(failure.status, failure.headers?.["retry-after"], failure.headers?.["ratelimit-reset"], failure.error);
  throw error;
}
/** Agent uses the authenticated session's resolved PDS and supplies PDS-bound DPoP. */
export class OAuthReadStateRepository implements ReadStateRepository {
  readonly viewerDid: string;
  private readonly agent: Agent;
  constructor(session: OAuthSession, private readonly assertCurrent: () => void) {
    this.viewerDid = session.did;
    this.agent = new Agent(session);
  }
  async getRecord(collection: string, rkey: string, cid?: string): Promise<RepositoryRecord | null> {
    this.assertCurrent();
    try {
      const result = await this.agent.com.atproto.repo.getRecord(
        { repo: this.viewerDid, collection, rkey, ...(cid ? { cid } : {}) },
        { signal: AbortSignal.timeout(20_000) });
      this.assertCurrent();
      if (!result.data.cid) throw new ReadStateError("invalid_cid");
      return { uri: result.data.uri, cid: result.data.cid, value: result.data.value };
    } catch (error) {
      if ((error as { error?: string }).error === "RecordNotFound") return null;
      return repositoryError(error);
    }
  }
  async putRecord(collection: string, rkey: string, value: Chunk | Manifest, swapRecord: string | null) {
    this.assertCurrent();
    try {
      const result = await this.agent.com.atproto.repo.putRecord({ repo: this.viewerDid, collection, rkey,
        record: value as unknown as Record<string, unknown>, swapRecord }, { signal: AbortSignal.timeout(20_000) });
      this.assertCurrent();
      return { uri: result.data.uri, cid: result.data.cid };
    } catch (error) { return repositoryError(error); }
  }
}
