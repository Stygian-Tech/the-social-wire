import type { OAuthSession } from "@atproto/oauth-client-browser";
import { PDSRequestError, ReadStateError, type Boundary, type CalendarSelection, type MigrationExportPage,
  type ReadStateMigrationGateway, type ReadStateStatus, type Reference } from "@thesocialwire/read-state";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";
import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";

export type PreparedReadState = { actedAt: string; legacyRevision: number; manifestCid?: string; calendar?: CalendarSelection; previewSubjectUris?: string[] }
  & ({ selection: "exact"; subjectUris: string[]; boundaries?: never }
    | { selection: "boundaries"; boundaries: Boundary[]; subjectUris?: never });
export class PDSReadStateGateway implements ReadStateMigrationGateway {
  constructor(private readonly oauth: OAuthSession, private readonly assertCurrent: () => void) {}
  private async request<T>(method: "getReadStateStatus" | "exportReadState" | "prepareReadState" | "confirmReadState", body?: unknown): Promise<T> {
    this.assertCurrent();
    const response = await gatewayFetch(this.oauth, socialWireXrpc[method],
      body === undefined ? {} : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
    this.assertCurrent();
    if (!response.ok) {
      if (response.status === 409) throw new ReadStateError("conflict");
      if (response.status === 401 || response.status === 403) throw new ReadStateError("reauthorize");
      throw new PDSRequestError(response.status, response.headers.get("retry-after") ?? undefined,
        response.headers.get("ratelimit-reset") ?? undefined);
    }
    return await response.json() as T;
  }
  status(): Promise<ReadStateStatus> { return this.request("getReadStateStatus"); }
  exportPage(cursor?: string, expectedLegacyRevision?: number): Promise<MigrationExportPage> {
    return this.request("exportReadState", { cursor, expectedLegacyRevision, limit: 500 });
  }
  confirm(reference: Reference, expectedLegacyRevision?: number): Promise<ReadStateStatus> {
    return this.request("confirmReadState", { manifestCid: reference.cid, expectedLegacyRevision });
  }
  prepare(scope: GatewayMarkAllReadScope, calendar?: { before: string; timeZone: string; referenceDate: string }, previewSubjectUris?: string[]): Promise<PreparedReadState> {
    return this.request("prepareReadState", { scope, ...calendar, ...(previewSubjectUris?.length ? { previewSubjectUris: previewSubjectUris.slice(0, 1000) } : {}) });
  }
}
