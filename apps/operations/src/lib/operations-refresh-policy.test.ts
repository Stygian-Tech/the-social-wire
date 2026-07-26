import { expect, test } from "bun:test"
import {
  DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS,
  liveRoutePollInterval,
} from "@/lib/operations-refresh-policy"

const base = {
  autoRefresh: true,
  visible: true,
  eventStreamState: "reconnecting" as const,
  fallbackMilliseconds: 5_000,
}

test("uses bounded fallback polling only while the live stream is unavailable", () => {
  expect(liveRoutePollInterval(base)).toBe(DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS)
  expect(liveRoutePollInterval({ ...base, eventStreamState: "live" })).toBe(false)
})

test("never polls hidden routes", () => {
  expect(liveRoutePollInterval({ ...base, visible: false })).toBe(false)
})

test("reserves client refetch time inside the five-second live-change budget", () => {
  const fallback = liveRoutePollInterval({ ...base, fallbackMilliseconds: 30_000 })
  expect(fallback).toBe(DEFAULT_LIVE_FALLBACK_POLL_MILLISECONDS)
  expect(Number(fallback) + 2_000).toBeLessThanOrEqual(5_000)
})
