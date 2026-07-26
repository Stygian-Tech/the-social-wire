import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { JetstreamEndpointStatus } from "@/components/operations/dashboard/jetstream-endpoint-status"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

test("ages a previously connected endpoint to Unknown", () => {
  const endpoints = demoOverview.jetstreamEndpoints ?? []
  const reference = new Date(new Date(demoOverview.refreshedAt).getTime() + 60_000).toISOString()
  render(<JetstreamEndpointStatus endpoints={endpoints} reference={reference} />)

  expect(screen.getAllByText("unknown").length).toBe(endpoints.length)
  expect(screen.getAllByText("Expired").length).toBe(endpoints.length)
  expect(screen.queryByText("connected")).toBeNull()
})

test("shows a recently failed endpoint as reconnecting during the grace period", () => {
  const endpoint = {
    ...demoOverview.jetstreamEndpoints![0]!,
    connectionState: "disconnected" as const,
    lastDisconnectedAt: demoOverview.refreshedAt,
    updatedAt: demoOverview.refreshedAt,
  }
  render(
    <JetstreamEndpointStatus
      endpoints={[endpoint]}
      reference={demoOverview.refreshedAt}
    />,
  )

  expect(screen.getByText("reconnecting")).toBeTruthy()
  expect(screen.queryByText("disconnected")).toBeNull()
})
