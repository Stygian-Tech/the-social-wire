import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const repositoryRoot = join(import.meta.dir, "../../..")
const goConfig = readFileSync(
  join(repositoryRoot, "services/jetstream-ingest/internal/config/config.go"),
  "utf8",
)
const goStore = readFileSync(
  join(repositoryRoot, "services/jetstream-ingest/internal/store/postgres.go"),
  "utf8",
)
const goInboxBatch = readFileSync(
  join(repositoryRoot, "services/jetstream-ingest/internal/store/inbox_batch.go"),
  "utf8",
)
const projectionPolicy = readFileSync(
  join(repositoryRoot, "packages/go/thinappviewcore/inbox_store.go"),
  "utf8",
)
const postgresStore = readFileSync(
  join(repositoryRoot, "packages/go/thinappviewcore/inbox_sql.go"),
  "utf8",
)
const migration = readFileSync(
  join(repositoryRoot, "database/migrations/20260816220000_jetstream_v2_scope_filtered_terminal.sql"),
  "utf8",
)
const replayRunbook = readFileSync(
  join(repositoryRoot, "docs/runbooks/operations/jetstream-v2-durable-replay.md"),
  "utf8",
)

const authorCollections = [
  "site.standard.document",
  "site.standard.entry",
  "com.standard.document",
  "com.standard.entry",
]
const viewerCollections = [
  "app.thesocialwire.finance.selection",
  "app.thesocialwire.sports.selection",
  "app.thesocialwire.readState",
  "app.skyreader.feed.subscription",
  "site.standard.graph.subscription",
]

function projectionCollections(name: string): string[] {
  const declaration = projectionPolicy.match(new RegExp(String.raw`var ${name} = \[\]string\{([^}]+)\}`))?.[1]
  if (!declaration) throw new Error(`Missing projection collection role ${name}`)
  return [...declaration.matchAll(/"([^"]+)"/g)].map(match => match[1]!).sort()
}

describe("Jetstream V2 role-aware scope policy", () => {
  it("keeps the Go admission and Go projection collection roles aligned", () => {
    expect(projectionCollections("publicationAuthorCollections")).toEqual([...authorCollections].sort())
    expect(projectionCollections("viewerCollections")).toEqual([...viewerCollections].sort())
    for (const collection of authorCollections) {
      expect(goInboxBatch).toContain(`'${collection}'`)
      expect(projectionPolicy).toContain(`"${collection}"`)
    }
    for (const collection of viewerCollections) {
      expect(goInboxBatch).toContain(`'${collection}'`)
      expect(projectionPolicy).toContain(`"${collection}"`)
    }
    expect(goStore).toContain("p.stageInboxEvents(ctx, tx, events[start:end])")
    expect(goInboxBatch).toContain("scope.author_did = incoming.repo_did")
    expect(goInboxBatch).toContain("feed.viewer_did = incoming.repo_did")
    expect(goInboxBatch).toContain("scope.viewer_did = incoming.repo_did")
    const authorAdmission = goInboxBatch.split("OR (incoming.collection IN ('site.standard.document'")[1]
      ?.split("OR (incoming.collection IN ('app.skyreader.feed.subscription'")[0]
    expect(authorAdmission).toContain("scope.author_did = incoming.repo_did")
    expect(authorAdmission).not.toContain("viewer_did")
    expect(goInboxBatch).toContain("ON CONFLICT (environment, source_generation, seq) DO NOTHING")
    expect(postgresStore).toContain("scope.author_did = i.repo_did")
    const authorClaim = postgresStore.split("OR (i.collection = ANY($4)")[1]?.split("OR (i.collection = ANY($5)")[0]
    expect(authorClaim).toContain("scope.author_did = i.repo_did")
    expect(authorClaim).not.toContain("viewer_did")
    // Admission and worker filtering use the same role lists, rather than accepting
    // an author document solely because its author is enrolled as a viewer.
    expect(projectionPolicy).toContain("publicationAuthorCollections, viewerCollections")
    expect(postgresStore).toContain("inbox.collection = ANY($5) AND NOT EXISTS")
    expect(postgresStore).toContain("inbox.collection = ANY($6)")
    expect(postgresStore).toContain("feed.viewer_did = i.repo_did")
    expect(goConfig).not.toContain('"app.thesocialwire.entryReadState",')
    expect(projectionPolicy).not.toContain('"app.thesocialwire.entryReadState",')
  })

  it("binds stable scope semantics to the durable source fingerprint", () => {
    expect(goConfig).toMatch(
      /DefaultScopePolicy\s*=\s*"publication-author-viewer-v1"/,
    )
    expect(goConfig).toMatch(
      /DefaultSourceGeneration\s*=\s*"jetstream-v2-us-west-v2"/,
    )
    expect(goConfig).toContain('strings.TrimSpace(scopePolicy)')
    const admissionVersion = goConfig.match(/DefaultScopePolicy\s*=\s*"([^"]+)"/)?.[1]
    const projectionVersion = projectionPolicy.match(/IngestionScopePolicyVersion\s*=\s*"([^"]+)"/)?.[1]
    expect(admissionVersion).toBe("publication-author-viewer-v1")
    expect(projectionVersion).toBe(admissionVersion)
  })

  it("records filtering as an audited terminal outcome instead of application or reconciliation", () => {
    expect(migration).toContain("'filtered_scope'")
    expect(migration).toContain("filtered_scope_policy")
    expect(migration).toContain("filtered_scope_at")
    expect(migration).toContain("applied_at IS NULL")
    expect(migration).toContain("reconciled_at IS NULL")
    expect(postgresStore).toContain("SET status = 'filtered_scope', filtered_scope_policy = $8")
    expect(postgresStore).toContain("filtered_scope_at = $3, applied_at = NULL, reconciled_at = NULL")
    expect(postgresStore).toContain("lease_owner = NULL, lease_token = NULL, lease_expires_at = NULL")
    expect(projectionPolicy).toContain("IngestionScopePolicyVersion, expires")
    expect(postgresStore).toContain("status IN ('applied', 'filtered_scope')")
    expect(postgresStore).toContain("status NOT IN ('applied', 'filtered_scope')")
  })

  it("retries an interrupted concurrent terminal-barrier build without dropping rolling-deploy coverage", () => {
    expect(migration).toContain("NOT index_state.indisvalid")
    expect(migration).toContain(
      "DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_inbox_terminal_barrier_v2",
    )
    expect(migration).toContain("invalid Jetstream V2 filtered terminal-barrier index remains")
    expect(migration).toContain("previous terminal-barrier index remains")
    expect(migration).not.toContain(
      "DROP INDEX CONCURRENTLY IF EXISTS public.idx_appview_ingestion_inbox_terminal_barrier;",
    )
  })

  it("keeps retired-generation incident resolution distinct from active-scope reconciliation", () => {
    expect(replayRunbook).toContain("`retired-generation-terminal-v1` policy")
    expect(replayRunbook).toContain("`open` or `recovering`")
    expect(replayRunbook).toContain("`verification_required` incidents")
    expect(replayRunbook).toContain("`replay_after_seq` is below the retired `last_staged_seq`")
    expect(replayRunbook).toContain("`last_applied_seq` has reached its recorded `last_staged_seq`")
    expect(replayRunbook).toContain("no pending, leased, or failed reconciliation request")
    expect(replayRunbook).toContain("It does not replace exact active-scope PDS reconciliation")
  })
})
