import { describe, expect, test } from "bun:test"
import { eventAffectsRoute, eventAffectsSupportData } from "@/lib/operations-event-routing"

describe("operations event routing", () => {
  test("refreshes only visible lifecycle domains", () => {
    expect(eventAffectsRoute({ type: "gap.update" }, "gaps/active")).toBe(true)
    expect(eventAffectsRoute({ type: "alert.update" }, "gaps/active")).toBe(false)
    expect(eventAffectsRoute({ type: "job.update" }, "backfills/needs_attention")).toBe(true)
  })

  test("refreshes history when a matching event can add a newly terminal row", () => {
    expect(eventAffectsRoute({ type: "gap.update" }, "gaps/history")).toBe(true)
    expect(eventAffectsRoute({ type: "job.update" }, "backfills/history")).toBe(true)
    expect(eventAffectsRoute({ type: "alert.update" }, "alerts/history")).toBe(true)
    expect(eventAffectsRoute({ type: "endpoint.update" }, "backfills/history")).toBe(false)
  })

  test("routes endpoint and command changes to supporting controls", () => {
    expect(eventAffectsSupportData({ type: "endpoint.update" })).toBe(true)
    expect(eventAffectsSupportData({ type: "command.insert" })).toBe(true)
    expect(eventAffectsSupportData({ type: "gap.update" })).toBe(false)
  })

  test("refreshes the ingestion route when its active-gap evidence changes", () => {
    expect(eventAffectsRoute({ type: "gap.update" }, "ingestion")).toBe(true)
    expect(eventAffectsRoute({ type: "job.update" }, "ingestion")).toBe(true)
    expect(eventAffectsRoute({ type: "alert.update" }, "ingestion")).toBe(false)
  })
})
