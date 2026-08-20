"use client"
import { FormEvent, useState } from "react"
import { Activity } from "lucide-react"
import { Alert, AlertDescription } from "@/components/ui/alert"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card"
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
      <Card size="sm" className="w-full max-w-sm bg-card/85">
        <CardHeader>
          <div className="mb-2 flex items-center gap-3">
            <span className="grid size-9 place-items-center rounded-lg bg-primary text-primary-foreground">
              <Activity className="size-5" />
            </span>
            <div>
              <h1 className="text-base font-semibold">The Social Wire</h1>
              <p className="ops-label">Operations</p>
            </div>
          </div>
          <CardTitle>Operator Sign-In</CardTitle>
          <CardDescription className="text-xs">
            Authenticate with ATProto. Access is enforced by the server-side operator DID allowlist.
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          {!accessConfigured ? (
            <Alert variant="destructive">
              <AlertDescription>No operator DID allowlist is configured for this deployment.</AlertDescription>
            </Alert>
          ) : forbidden ? (
            <Alert variant="destructive">
              <AlertDescription>This DID is authenticated but not authorized for operations.</AlertDescription>
            </Alert>
          ) : sessionExpired ? (
            <Alert variant="warning">
              <AlertDescription>Your operator session expired. Sign in again to resume live operations data.</AlertDescription>
            </Alert>
          ) : null}
          <form onSubmit={submit}>
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
        </CardContent>
      </Card>
    </main>
  )
}
