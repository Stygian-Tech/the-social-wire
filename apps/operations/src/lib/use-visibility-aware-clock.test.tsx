import { afterEach, expect, jest, test } from "bun:test"
import { act, renderHook } from "@testing-library/react"
import { useVisibilityAwareClock } from "@/lib/use-visibility-aware-clock"

afterEach(() => jest.useRealTimers())

test("ages visible evidence and pauses clock work while the document is hidden", () => {
  jest.useFakeTimers()
  const start = Date.now()
  const hook = renderHook(({ visible }) => useVisibilityAwareClock(visible, 1_000), {
    initialProps: { visible: true },
  })
  expect(hook.result.current).toBe(start)

  act(() => {
    jest.advanceTimersByTime(1_000)
  })
  expect(hook.result.current).toBe(start + 1_000)

  hook.rerender({ visible: false })
  act(() => {
    jest.advanceTimersByTime(59_000)
  })
  expect(hook.result.current).toBe(start + 1_000)

  hook.rerender({ visible: true })
  expect(hook.result.current).toBe(start + 60_000)
})
