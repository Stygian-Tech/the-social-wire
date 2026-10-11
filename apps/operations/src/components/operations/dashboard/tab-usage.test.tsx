import { afterEach, expect, test } from "bun:test"
import { cleanup, render, screen } from "@testing-library/react"
import { TabUsage } from "./tab-usage"
import { assertTabUsage } from "@/lib/tab-usage-contract"
const usage = { observedAt: "2026-10-11T12:00:00Z", trackingStart: "2026-10-11T00:00:00Z", dau: 2, wau: 3, mau: 5, tabs: [{ tab: "messages", dau: 1, wau: 2, mau: 4, opens: 10, dwellMs: 600000 }] }
afterEach(cleanup)
test("shows all three deduplicated active-user windows and per-tab visits/dwell", () => {
  render(<TabUsage usage={usage} />)
  expect(screen.getAllByText("DAUs").length).toBe(2)
  expect(screen.getAllByText("WAUs").length).toBe(2)
  expect(screen.getAllByText("MAUs").length).toBe(2)
  expect(screen.getByText("Messages")).toBeTruthy()
  expect(screen.getByText("10 min")).toBeTruthy()
  expect(screen.getByText("1 min")).toBeTruthy()
  expect(() => assertTabUsage(usage)).not.toThrow()
})
test("rejects unknown labels, raw identities and invalid count windows", () => {
  expect(() => assertTabUsage({ ...usage, viewerDid: "did:plc:private" })).toThrow()
  expect(() => assertTabUsage({ ...usage, dau: 99 })).toThrow()
  expect(() => assertTabUsage({ ...usage, tabs: [{ ...usage.tabs[0], tab: "/social/messages?to=alice" }] })).toThrow()
})
test("distinguishes no observations from unavailable telemetry", () => {
  const view = render(<TabUsage />); expect(screen.getByText("Tab usage telemetry is unavailable.")).toBeTruthy()
  view.rerender(<TabUsage usage={{ ...usage, dau: 0, wau: 0, mau: 0, tabs: [], trackingStart: null }} />)
  expect(screen.getByText(/No tab usage has been observed/)).toBeTruthy()
})

test("labels isolated local telemetry without widening the console environment", () => {
  render(<TabUsage usage={{ ...usage, sourceEnvironment: "local" }} />)
  expect(screen.getByText("Local Web Activity")).toBeTruthy()
  expect(() => assertTabUsage({ ...usage, sourceEnvironment: "local" })).not.toThrow()
  expect(() => assertTabUsage({ ...usage, sourceEnvironment: "unknown" })).toThrow()
})
