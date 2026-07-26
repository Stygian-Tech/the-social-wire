import { afterEach, describe, expect, it } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { DatabaseObservability } from "@/components/operations/dashboard/database-observability"
import { demoOverview } from "@/lib/demo-data"

afterEach(cleanup)

describe("DatabaseObservability", () => {
  it("summarizes database dependencies and correlated query spans", () => {
    render(<DatabaseObservability overview={demoOverview} />)

    expect(screen.getByText("Database Availability").nextElementSibling?.textContent).toBe("Ready")
    expect(screen.queryByText("Database Request Volume")).toBeNull()
    expect(screen.getByText("Estimated Live Rows", { selector: "p" }).nextElementSibling?.textContent).toBe("9,842,117")
    expect(screen.getByText("Connected Backends").nextElementSibling?.textContent).toBe("8")
    expect(screen.getByText("Cache Hit Ratio").nextElementSibling?.textContent).toBe("99.7%")
    expect(screen.getByText("Postgres Stats Reset").nextElementSibling?.textContent).not.toBe("Unavailable")
  })

  it("uses the AppView database dependency probe for availability", () => {
    render(
      <DatabaseObservability
        overview={{
          ...demoOverview,
          services: demoOverview.services.map((service) => ({
            ...service,
            dependencyState: { appview_database: "healthy" },
          })),
        }}
      />,
    )

    expect(screen.getByText("Database Availability").nextElementSibling?.textContent).toBe("Ready")
  })

  it("withholds physically invalid ratios and counts", () => {
    render(
      <DatabaseObservability
        overview={{
          ...demoOverview,
          database: {
            ...demoOverview.database!,
            cacheHitRatio: 1.5,
            activeConnections: -1,
            connectedBackends: -1,
          },
        }}
      />,
    )

    expect(screen.getByText("Cache Hit Ratio").nextElementSibling?.textContent).toBe("—")
    expect(screen.getByText("Connected Backends").nextElementSibling?.textContent).toBe("—")
  })

  it("renders a missing Postgres cache-hit observation as unavailable", () => {
    const { cacheHitRatio: _cacheHitRatio, ...database } = demoOverview.database!
    void _cacheHitRatio
    render(<DatabaseObservability overview={{ ...demoOverview, database }} />)

    expect(screen.getByText("Cache Hit Ratio").nextElementSibling?.textContent).toBe("—")
  })

  it("labels a missing Postgres statistics reset observation as unavailable", () => {
    const { statsResetAt: _statsResetAt, ...database } = demoOverview.database!
    void _statsResetAt
    render(<DatabaseObservability overview={{ ...demoOverview, database }} />)

    expect(screen.getByText("Postgres Stats Reset").nextElementSibling?.textContent).toBe("Unavailable")
  })

  it("ages database availability and observation status to Unknown", () => {
    const referenceTime = new Date(new Date(demoOverview.refreshedAt).getTime() + 61_000).toISOString()
    render(<DatabaseObservability overview={demoOverview} referenceTime={referenceTime} />)

    expect(screen.getByText("Database Availability").nextElementSibling?.textContent).toBe("Unknown")
    expect(screen.getByText(/Unknown · expired/)).toBeTruthy()
  })
})
