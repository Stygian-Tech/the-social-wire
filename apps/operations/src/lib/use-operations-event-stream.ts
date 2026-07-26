"use client"

import { useEffect, useRef, useState } from "react"
import type { OAuthSession } from "@/lib/auth"
import {
  OperationsHttpError,
  subscribeOperationsEvents,
  type OperationsEvent,
} from "@/lib/operations-api"

export type EventStreamState = "disabled" | "connecting" | "live" | "reconnecting"
export const EVENT_STREAM_HEARTBEAT_TIMEOUT_MILLISECONDS = 35_000

export function useOperationsEventStream({
  enabled,
  session,
  path,
  retryMilliseconds = 1_000,
  heartbeatTimeoutMilliseconds = EVENT_STREAM_HEARTBEAT_TIMEOUT_MILLISECONDS,
  onEvent,
  onLive,
  onCursorExpired,
}: {
  enabled: boolean
  session: OAuthSession | null
  path?: string
  retryMilliseconds?: number
  heartbeatTimeoutMilliseconds?: number
  onEvent: (event: OperationsEvent) => void
  onLive?: () => void | Promise<void>
  onCursorExpired?: () => void | Promise<void>
}) {
  const [state, setState] = useState<EventStreamState>("disabled")
  const callback = useRef(onEvent)
  const liveCallback = useRef(onLive)
  const cursorExpiredCallback = useRef(onCursorExpired)
  const lastEventId = useRef<string | undefined>(undefined)

  useEffect(() => {
    callback.current = onEvent
  }, [onEvent])
  useEffect(() => {
    liveCallback.current = onLive
  }, [onLive])
  useEffect(() => {
    cursorExpiredCallback.current = onCursorExpired
  }, [onCursorExpired])

  useEffect(() => {
    if (!enabled || !session || !path) {
      return
    }
    const lifecycleController = new AbortController()
    let connectionController: AbortController | undefined
    let retry: ReturnType<typeof setTimeout> | undefined
    let heartbeatDeadline: ReturnType<typeof setTimeout> | undefined
    let attempt = 0

    const clearHeartbeatDeadline = () => {
      if (heartbeatDeadline) clearTimeout(heartbeatDeadline)
      heartbeatDeadline = undefined
    }
    const markTransportActivity = () => {
      clearHeartbeatDeadline()
      heartbeatDeadline = setTimeout(() => {
        if (lifecycleController.signal.aborted) return
        setState("reconnecting")
        connectionController?.abort(new DOMException("Operations event stream heartbeat expired", "TimeoutError"))
      }, Math.max(1_000, heartbeatTimeoutMilliseconds))
    }

    const connect = async () => {
      if (lifecycleController.signal.aborted) return
      setState(attempt ? "reconnecting" : "connecting")
      connectionController = new AbortController()
      const abortConnection = () => connectionController?.abort(lifecycleController.signal.reason)
      lifecycleController.signal.addEventListener("abort", abortConnection, { once: true })
      try {
        await subscribeOperationsEvents({
          session,
          path,
          lastEventId: lastEventId.current,
          signal: connectionController.signal,
          onConnected: () => {
            attempt = 0
            setState("live")
            markTransportActivity()
            void liveCallback.current?.()
          },
          onTransportActivity: markTransportActivity,
          onEvent: (event) => {
            if (event.id) lastEventId.current = event.id
            callback.current(event)
          },
        })
      } catch (error) {
        if (error instanceof OperationsHttpError && error.status === 410) {
          lastEventId.current = undefined
          await cursorExpiredCallback.current?.()
          attempt = 0
        }
        // Route-aware polling remains active while the stream reconnects.
      } finally {
        lifecycleController.signal.removeEventListener("abort", abortConnection)
        clearHeartbeatDeadline()
      }
      if (lifecycleController.signal.aborted) return
      attempt += 1
      setState("reconnecting")
      retry = setTimeout(
        () => void connect(),
        Math.min(30_000, Math.max(1_000, retryMilliseconds) * 2 ** Math.max(0, attempt - 1)),
      )
    }
    void connect()
    return () => {
      lifecycleController.abort()
      connectionController?.abort()
      if (retry) clearTimeout(retry)
      clearHeartbeatDeadline()
    }
  }, [enabled, heartbeatTimeoutMilliseconds, path, retryMilliseconds, session])

  return enabled && session && path ? state : "disabled"
}
