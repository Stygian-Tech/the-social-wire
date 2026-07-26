import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { RequestTable } from "@/components/operations/dashboard/request-table"
import type { Span } from "@/lib/operations-types"

afterEach(cleanup)

const span: Span = {
  id: "span-1",
  environment: "dev",
  traceId: "trace-1",
  service: "appview",
  name: "appview.request",
  startedAt: "2026-07-20T20:00:00.000Z",
  durationMs: 25,
  status: "ok",
  attributes: {
    route_template: "/v1/appview/entries",
    method: "GET",
    status_class: "2xx",
    environment: "dev",
  },
  expiresAt: "2026-07-27T20:00:00.000Z",
}

describe("RequestTable", () => {
  it("shows recorded attributes and no inferred request internals", () => {
    render(<RequestTable spans={[span]} />)

    expect(screen.getAllByText("/v1/appview/entries").length).toBeGreaterThan(0)
    expect(screen.getAllByText(/GET/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/2xx/).length).toBeGreaterThan(0)
    expect(screen.queryByText("JWT")).toBeNull()
    expect(screen.queryByText("3 ms")).toBeNull()
    expect(screen.queryByText("50")).toBeNull()
  })
})
