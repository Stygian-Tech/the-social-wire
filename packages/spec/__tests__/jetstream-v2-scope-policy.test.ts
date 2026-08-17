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
const swiftPolicy = readFileSync(
  join(repositoryRoot, "packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/ThinAppViewStore.swift"),
  "utf8",
)
const postgresStore = readFileSync(
  join(repositoryRoot, "packages/swift/ThinAppViewCore/Sources/ThinAppViewCore/PostgresThinAppViewStore.swift"),
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
  "app.skyreader.feed.subscription",
  "site.standard.graph.subscription",
]

describe("Jetstream V2 role-aware scope policy", () => {
  it("keeps the Go admission and Swift projection collection roles aligned", () => {
    for (const collection of authorCollections) {
      expect(goStore).toContain(`'${collection}'`)
      expect(swiftPolicy).toContain(`"${collection}"`)
    }
    for (const collection of viewerCollections) {
      expect(goStore).toContain(`'${collection}'`)
      expect(swiftPolicy).toContain(`"${collection}"`)
    }
    expect(goStore).toContain("scope.author_did = $7")
    expect(goStore).toContain("feed.viewer_did = $7")
    expect(postgresStore).toContain("scope.author_did = inbox.repo_did")
    expect(postgresStore).toContain("feed.viewer_did = inbox.repo_did")
    expect(goConfig).not.toContain('"app.thesocialwire.entryReadState",')
    expect(swiftPolicy).not.toContain('"app.thesocialwire.entryReadState",')
  })

  it("binds stable scope semantics to the durable source fingerprint", () => {
    expect(goConfig).toContain('DefaultScopePolicy      = "publication-author-viewer-v1"')
    expect(goConfig).toContain('DefaultSourceGeneration = "jetstream-v2-us-west-v2"')
    expect(goConfig).toContain('strings.TrimSpace(scopePolicy)')
    expect(swiftPolicy).toContain('version = "publication-author-viewer-v1"')
  })

  it("records filtering as an audited terminal outcome instead of application or reconciliation", () => {
    expect(migration).toContain("'filtered_scope'")
    expect(migration).toContain("filtered_scope_policy")
    expect(migration).toContain("filtered_scope_at")
    expect(migration).toContain("applied_at IS NULL")
    expect(migration).toContain("reconciled_at IS NULL")
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
