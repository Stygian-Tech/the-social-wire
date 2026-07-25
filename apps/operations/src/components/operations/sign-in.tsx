"use client"
import { FormEvent, useState } from "react"
import { Activity } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Field, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { useOperationsAuth } from "@/lib/auth-context"
import { operatorAccessConfigured } from "@/lib/operator-access"

export function OperatorSignIn() {
  const { signIn, forbidden, sessionExpired } = useOperationsAuth()
  const accessConfigured = operatorAccessConfigured()
  const [handle, setHandle] = useState("")
  const [busy, setBusy] = useState(false)
  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setBusy(true)
    try {
      await signIn(handle.trim())
    } finally {
      setBusy(false)
    }
  }
  return (
    <main className="grid min-h-svh place-items-center p-5">
      <section className="ops-panel w-full max-w-sm p-6">
        <div className="mb-5 flex items-center gap-3">
          <span className="grid size-9 place-items-center rounded-md bg-primary text-primary-foreground">
            <Activity className="size-5" />
          </span>
          <div>
            <h1 className="text-base font-semibold">The Social Wire</h1>
            <p className="ops-label">Operations</p>
          </div>
        </div>
        <h2 className="text-sm font-semibold">Operator Sign-In</h2>
        <p className="mt-1 text-xs text-muted-foreground">
          Authenticate with ATProto. Access is enforced by the server-side operator DID allowlist.
        </p>
        {!accessConfigured ? (
          <p
            role="alert"
            className="mt-3 rounded-md border border-destructive/30 bg-danger-surface p-2 text-xs text-destructive"
          >
            No operator DID allowlist is configured for this deployment.
          </p>
        ) : forbidden ? (
          <p
            role="alert"
            className="mt-3 rounded-md border border-destructive/30 bg-danger-surface p-2 text-xs text-destructive"
          >
            This DID is authenticated but not authorized for operations.
          </p>
        ) : sessionExpired ? (
          <p
            role="alert"
            className="mt-3 rounded-md border border-warning/30 bg-warning-surface p-2 text-xs text-warning"
          >
            Your operator session expired. Sign in again to resume live operations data.
          </p>
        ) : null}
        <form onSubmit={submit} className="mt-5">
          <FieldGroup>
            <Field>
              <FieldLabel htmlFor="handle">Handle</FieldLabel>
              <Input
                id="handle"
                value={handle}
                onChange={(event) => setHandle(event.target.value)}
                placeholder="you.example.com"
                autoComplete="username"
                required
              />
            </Field>
            <Button type="submit" disabled={busy || !accessConfigured}>
              {busy ? "Redirecting…" : "Continue With ATProto"}
            </Button>
          </FieldGroup>
        </form>
      </section>
    </main>
  )
}
