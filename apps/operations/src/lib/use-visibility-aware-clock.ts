"use client"

import { useEffect, useState } from "react"

export function useVisibilityAwareClock(visible: boolean, intervalMilliseconds = 5_000) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    if (!visible) return
    const update = () => setNow(Date.now())
    update()
    const timer = window.setInterval(update, Math.max(1_000, intervalMilliseconds))
    return () => window.clearInterval(timer)
  }, [intervalMilliseconds, visible])

  return now
}
