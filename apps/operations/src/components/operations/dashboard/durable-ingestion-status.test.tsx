import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { DurableIngestionStatus } from "@/components/operations/dashboard/durable-ingestion-status"

afterEach(cleanup)

describe("DurableIngestionStatus", () => {
  it("shows separate staged and terminal-prefix watermarks without a sequence delta", () => {
    render(
      <DurableIngestionStatus
        durability={{
          environment: "dev",
          checkpoints: [{
            environment: "dev",
            sourceGeneration: "v2-us-west-1",
            sourceHost: "jetstream.us-west.bsky.network",
            streamNSID: "network.bsky.jetstream.subscribeEvents",
            filterFingerprint: "filters-v1",
            cursorKind: "jetstream_v2_seq",
            lastStagedSequence: 42_000,
            lastAppliedSequence: 41_900,
            replayState: "live",
            replayBytesDownloaded: 2_048,
            replayRetryCount: 1,
            replayRangeResumeCount: 2,
            updatedAt: "2026-08-15T20:00:00.000Z",
          }],
          inbox: { pending: 1, leased: 2, retrying: 3, applied: 100, filteredScope: 27, deadLetters: 0, total: 133 },
          incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 4, ignored: 1 },
          replayBytesRolling24Hours: 1_048_576,
          generatedAt: "2026-08-15T20:00:00.000Z",
        }}
      />,
    )

    expect(screen.getByText("42,000")).toBeTruthy()
    expect(screen.getByText("41,900")).toBeTruthy()
    expect(screen.getByText("1 / 2 / 3")).toBeTruthy()
    expect(screen.getByText("Filtered Outside Scope")).toBeTruthy()
    expect(screen.getByText("27")).toBeTruthy()
    expect(screen.getByText("Unresolved Dead Letters")).toBeTruthy()
    expect(screen.getByText("1.0 MiB")).toBeTruthy()
    expect(screen.queryByText(/Cursor Delta/)).toBeNull()
    expect(screen.getByText(/numeric difference is never treated as missing events/)).toBeTruthy()
    expect(screen.getByText(/were not projected or reconciled/)).toBeTruthy()
  })

  it("labels a bounded completion as a healthy The Wire snapshot", () => {
    render(
      <DurableIngestionStatus
        durability={{
          environment: "dev",
          checkpoints: [{
            environment: "dev",
            sourceGeneration: "wire-v2",
            sourceHost: "jetstream.us-west.bsky.network",
            streamNSID: "network.bsky.jetstream.subscribeEvents",
            filterFingerprint: "wire-v1",
            cursorKind: "jetstream_v2_seq",
            lastStagedSequence: 200,
            replayState: "snapshot_complete",
            replayAfterSequence: 100,
            replayBeforeSequence: 200,
            replaySealedSequence: 200,
            replayBytesDownloaded: 2_048,
            replayRetryCount: 0,
            replayRangeResumeCount: 1,
            updatedAt: "2026-08-20T20:00:00.000Z",
          }],
          inbox: { pending: 0, leased: 0, retrying: 0, applied: 100, deadLetters: 0, total: 100 },
          incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
          replayBytesRolling24Hours: 2_048,
          generatedAt: "2026-08-20T20:00:00.000Z",
        }}
      />,
    )

    expect(screen.getByText("The Wire Snapshot Complete")).toBeTruthy()
    expect(screen.getByText("Healthy")).toBeTruthy()
    expect(screen.getAllByText("200").length).toBeGreaterThanOrEqual(2)
    expect(screen.queryByText("snapshot_complete")).toBeNull()
  })

  it("does not let snapshot completion hide an overdue downstream inbox", () => {
    render(
      <DurableIngestionStatus
        durability={{
          environment: "dev",
          checkpoints: [{
            environment: "dev",
            sourceGeneration: "wire-v2",
            sourceHost: "jetstream.us-west.bsky.network",
            streamNSID: "network.bsky.jetstream.subscribeEvents",
            filterFingerprint: "wire-v1",
            cursorKind: "jetstream_v2_seq",
            replayState: "snapshot_complete",
            replayAfterSequence: 100,
            replayBeforeSequence: 200,
            replaySealedSequence: 200,
            replayBytesDownloaded: 2_048,
            replayRetryCount: 0,
            replayRangeResumeCount: 0,
            updatedAt: "2026-08-20T20:00:00.000Z",
          }],
          inbox: {
            pending: 1,
            leased: 0,
            retrying: 0,
            applied: 99,
            deadLetters: 0,
            total: 100,
            oldestPendingAgeSeconds: 61,
          },
          incidents: { open: 0, recovering: 0, verificationRequired: 0, resolved: 0, ignored: 0 },
          replayBytesRolling24Hours: 2_048,
          generatedAt: "2026-08-20T20:00:00.000Z",
        }}
      />,
    )

    expect(screen.getByText("Attention")).toBeTruthy()
    expect(screen.getByText("The Wire Snapshot Complete")).toBeTruthy()
  })
})
