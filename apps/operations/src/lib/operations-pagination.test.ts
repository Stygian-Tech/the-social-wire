import { describe, expect, test } from "bun:test"
import { nextOperationsPage, previousOperationsPage } from "@/lib/operations-pagination"

describe("operations lifecycle pagination", () => {
  for (const routeKey of [
    "gaps/active",
    "gaps/history",
    "backfills/active",
    "backfills/needs_attention",
    "backfills/history",
    "alerts/active",
    "alerts/history",
  ]) {
    test(`preserves Previous navigation for ${routeKey}`, () => {
      const secondPage = nextOperationsPage(routeKey, `${routeKey}-page-2`, undefined, [])
      expect(previousOperationsPage(secondPage, routeKey)).toEqual({
        route: routeKey,
        cursor: undefined,
        history: [],
      })
    })
  }

  test("does not reuse cursor history from a different lifecycle view", () => {
    expect(
      previousOperationsPage(
        { route: "gaps/history", cursor: "history-page-2", history: [undefined] },
        "gaps/active",
      ),
    ).toEqual({ route: "gaps/active", cursor: undefined, history: [] })
  })
})
