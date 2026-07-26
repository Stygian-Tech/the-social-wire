import { expect, test } from "bun:test"
import { render, screen } from "@testing-library/react"
import {
  EvidenceInventory,
  evidenceAgeAtReference,
  orderedEvidenceEntries,
} from "@/components/operations/dashboard/evidence-inventory"
import { demoOverview } from "@/lib/demo-data"

test("renders source, accuracy, coverage, and degradation without hiding them behind hover", () => {
  render(<EvidenceInventory overview={demoOverview} />)
  expect(screen.getByText("Synthetic demo fixture")).toBeTruthy()
  expect(screen.getAllByText("estimated").length).toBeGreaterThan(0)
  expect(screen.getAllByText("100%").length).toBeGreaterThan(0)
  expect(screen.getAllByText(/illustrative/).length).toBeGreaterThan(0)
})

test("retains the reported evidence age when the shared clock slightly predates a new response", () => {
  expect(
    evidenceAgeAtReference(
      7,
      "2026-07-22T20:00:00.100Z",
      "2026-07-22T20:00:00.000Z",
    ),
  ).toBe(7)

  const overview = {
    ...demoOverview,
    refreshedAt: "2026-07-22T20:00:00.100Z",
    evidence: {
      ...demoOverview.evidence,
      overview: {
        ...demoOverview.evidence.overview,
        generatedAt: "2026-07-22T20:00:00.100Z",
        ageSeconds: 7,
      },
    },
  }
  render(<EvidenceInventory overview={overview} referenceTime="2026-07-22T20:00:00.000Z" />)
  expect(screen.getByText("7s")).toBeTruthy()
  expect(screen.queryByText("Unknown")).toBeNull()
})

test("keeps evidence cards in a stable semantic order across response key ordering", () => {
  const entries = orderedEvidenceEntries({
    metrics: demoOverview.evidence.overview,
    ingestion: demoOverview.evidence.ingestion,
    overview: demoOverview.evidence.overview,
    database: demoOverview.evidence.database,
    services: demoOverview.evidence.services,
  })

  expect(entries.map(([section]) => section)).toEqual([
    "overview",
    "services",
    "ingestion",
    "database",
    "metrics",
  ])
})
