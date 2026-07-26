import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { GapInvestigationContent } from "@/components/operations/gaps/gap-investigation-content"
import { demoGapInvestigation } from "@/lib/demo-data"

afterEach(cleanup)

describe("GapInvestigationContent", () => {
  it("shows a qualified trigger and the evidence that supports it", () => {
    render(<GapInvestigationContent investigation={demoGapInvestigation("gap-20250516-001")} />)

    expect(screen.getByText("Likely Trigger")).toBeTruthy()
    expect(screen.getByText("High Confidence")).toBeTruthy()
    expect(screen.getByText("Indexing failure interrupted commit advancement")).toBeTruthy()
    expect(screen.getAllByText("Supports Assessment")).toHaveLength(2)
    expect(screen.getByText("What This Does Not Prove")).toBeTruthy()
    expect(screen.getByText("Open Trace")).toBeTruthy()
  })

  it("labels an unsupported assessment as insufficient evidence", () => {
    const investigation = demoGapInvestigation("gap-20250516-001")
    render(
      <GapInvestigationContent
        investigation={{
          ...investigation,
          assessment: {
            ...investigation.assessment,
            confidence: "insufficient",
            title: "Cause not determined from retained telemetry",
            summary: "No supported trigger was retained.",
            evidenceIds: ["gap-detected"],
          },
        }}
      />,
    )

    expect(screen.getByText("Insufficient Evidence")).toBeTruthy()
    expect(screen.getByText("Cause not determined from retained telemetry")).toBeTruthy()
  })
})
