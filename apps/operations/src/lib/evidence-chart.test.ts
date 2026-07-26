import { describe, expect, test } from "bun:test"
import { evidenceChartModel } from "@/lib/evidence-chart"

describe("evidenceChartModel", () => {
  test("keeps missing buckets as visible path gaps", () => {
    const model = evidenceChartModel(
      [
        { timestamp: 1, value: 2 },
        { timestamp: 2, value: null },
        { timestamp: 3, value: 0 },
        { timestamp: 4, value: 4 },
      ],
      640,
      180,
    )

    expect(model.paths).toHaveLength(2)
    expect(model.paths[0]).toStartWith("M")
    expect(model.paths[1]).toContain("L")
    expect(model.latest).toBe(4)
    expect(model.coverage).toBe(0.75)
  })

  test("preserves observed zero and withholds invalid values", () => {
    const model = evidenceChartModel(
      [
        { timestamp: 1, value: 0 },
        { timestamp: 2, value: -1 },
        { timestamp: 3, value: Number.NaN },
      ],
      640,
      180,
    )

    expect(model.points.map(({ value }) => value)).toEqual([0])
    expect(model.latest).toBeNull()
  })

  test("exposes the displayed scale while preserving an observed all-zero latest value", () => {
    const model = evidenceChartModel(
      [
        { timestamp: 1, value: 0 },
        { timestamp: 2, value: 0 },
      ],
      640,
      180,
    )

    expect(model.maximum).toBe(1)
    expect(model.latest).toBe(0)
    expect(model.points.every(({ value }) => value === 0)).toBe(true)
  })

  test("plots thresholds and observations in the same vertical domain", () => {
    const model = evidenceChartModel(
      [{ timestamp: 1, value: 5 }],
      640,
      180,
      { top: 12, right: 16, bottom: 26, left: 48 },
      10,
    )

    expect(model.maximum).toBe(10)
    expect(model.points[0]?.y).toBe(83)
  })
})
