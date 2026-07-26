import { afterEach, describe, expect, jest, test } from "bun:test"
import { act, renderHook } from "@testing-library/react"
import type { OAuthSession } from "@/lib/auth"
import { useOperationsEventStream } from "@/lib/use-operations-event-stream"

const originalDemoMode = process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE

afterEach(() => {
  jest.useRealTimers()
  if (originalDemoMode === undefined) delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
  else process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE = originalDemoMode
})

describe("useOperationsEventStream", () => {
  test("clears a 410 resume cursor, refreshes current state, and reconnects without the expired ID", async () => {
    jest.useFakeTimers()
    delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
    const requestedCursors: Array<string | null> = []
    let requests = 0
    let cursorRefreshes = 0
    let liveSynchronizations = 0
    const session = {
      fetchHandler: async (_url: string, init?: RequestInit) => {
        requests += 1
        requestedCursors.push(new Headers(init?.headers).get("Last-Event-ID"))
        if (requests === 1)
          return new Response("id: 1\nevent: gap.update\ndata: {\"gapId\":\"gap-1\"}\n\n", {
            status: 200,
            headers: { "Content-Type": "text/event-stream" },
          })
        if (requests === 2) return Response.json({ error: "expired_cursor" }, { status: 410 })
        return new Response(": heartbeat\n\n", {
          status: 200,
          headers: { "Content-Type": "text/event-stream" },
        })
      },
    } as unknown as OAuthSession

    const hook = renderHook(() =>
      useOperationsEventStream({
        enabled: true,
        session,
        path: "/v1/operations/events/stream",
        retryMilliseconds: 1_000,
        onEvent: () => undefined,
        onLive: () => {
          liveSynchronizations += 1
        },
        onCursorExpired: async () => {
          cursorRefreshes += 1
        },
      }),
    )

    await flushEffects()
    await advance(1_000)
    await advance(1_000)

    expect(requestedCursors).toEqual([null, "1", null])
    expect(cursorRefreshes).toBe(1)
    expect(liveSynchronizations).toBe(2)
    hook.unmount()
  })

  test("comment bytes extend liveness but an expired heartbeat allowance reconnects", async () => {
    jest.useFakeTimers()
    delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
    const encoder = new TextEncoder()
    let streamController: ReadableStreamDefaultController<Uint8Array> | undefined
    let requests = 0
    const session = {
      fetchHandler: async () => {
        requests += 1
        return new Response(
          new ReadableStream<Uint8Array>({
            start(controller) {
              streamController = controller
            },
          }),
          { status: 200, headers: { "Content-Type": "text/event-stream" } },
        )
      },
    } as unknown as OAuthSession
    const hook = renderHook(() =>
      useOperationsEventStream({
        enabled: true,
        session,
        path: "/v1/operations/events/stream",
        retryMilliseconds: 1_000,
        heartbeatTimeoutMilliseconds: 1_000,
        onEvent: () => undefined,
      }),
    )

    await flushEffects()
    expect(hook.result.current).toBe("live")
    await advance(900)
    await act(async () => {
      streamController?.enqueue(encoder.encode(": heartbeat\n\n"))
      await Promise.resolve()
    })
    await advance(200)
    expect(hook.result.current).toBe("live")
    await advance(801)
    expect(hook.result.current).toBe("reconnecting")
    await advance(1_000)
    expect(requests).toBe(2)
    hook.unmount()
  })

  test("unmount aborts the active connection and prevents a scheduled reconnect", async () => {
    jest.useFakeTimers()
    delete process.env.NEXT_PUBLIC_OPERATIONS_DEMO_MODE
    let requests = 0
    let cancelled = 0
    const session = {
      fetchHandler: async () => {
        requests += 1
        return new Response(
          new ReadableStream<Uint8Array>({
            cancel() {
              cancelled += 1
            },
          }),
          { status: 200, headers: { "Content-Type": "text/event-stream" } },
        )
      },
    } as unknown as OAuthSession
    const hook = renderHook(() =>
      useOperationsEventStream({
        enabled: true,
        session,
        path: "/v1/operations/events/stream",
        retryMilliseconds: 1_000,
        heartbeatTimeoutMilliseconds: 1_000,
        onEvent: () => undefined,
      }),
    )

    await flushEffects()
    hook.unmount()
    await advance(5_000)

    expect(cancelled).toBe(1)
    expect(requests).toBe(1)
  })
})

async function flushEffects() {
  await act(async () => {
    await Promise.resolve()
    await Promise.resolve()
  })
}

async function advance(milliseconds: number) {
  await act(async () => {
    jest.advanceTimersByTime(milliseconds)
    await Promise.resolve()
    await Promise.resolve()
  })
}
