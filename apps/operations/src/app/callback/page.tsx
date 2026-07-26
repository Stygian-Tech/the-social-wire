"use client"
import { useEffect, useState } from "react"
import { finishSignIn } from "@/lib/auth"

export default function CallbackPage() {
  const [error, setError] = useState<string>()
  useEffect(() => {
    void finishSignIn()
      .then(() => window.location.replace("/"))
      .catch((value: unknown) => setError(value instanceof Error ? value.message : "OAuth callback failed"))
  }, [])
  return (
    <main className="grid min-h-svh place-items-center p-6">
      <div className="ops-panel max-w-md p-6 text-center">
        <h1 className="text-base font-semibold">Completing Operator Sign-In</h1>
        <p className="mt-2 text-xs text-muted-foreground">{error ?? "Verifying the DPoP-bound OAuth session…"}</p>
      </div>
    </main>
  )
}
