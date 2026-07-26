"use client"

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useId, useState } from "react"
import {
  AlertDialog,
  AlertDialogClose,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { Field, FieldDescription, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { Toast } from "@/components/ui/toast"
import { OperationsRequestError } from "@/components/operations/operations-request-error"
import { useOperationsAuth } from "@/lib/auth-context"
import { operationsRequest } from "@/lib/operations-api"
import type { EnvironmentName } from "@/lib/operations-types"

export function OperatorActionDialog({
  environment,
  path,
  label,
  auditNoteRequired = false,
  expectedVersion,
  disabled = false,
  disabledReason,
  destructive = false,
  targetLabel,
}: {
  environment: EnvironmentName
  path: string
  label: string
  auditNoteRequired?: boolean
  expectedVersion?: number
  disabled?: boolean
  disabledReason?: string
  destructive?: boolean
  targetLabel?: string
}) {
  const { session } = useOperationsAuth()
  const queryClient = useQueryClient()
  const fieldId = useId()
  const [open, setOpen] = useState(false)
  const [auditNote, setAuditNote] = useState("")
  const [confirmation, setConfirmation] = useState("")
  const [idempotencyKey, setIdempotencyKey] = useState("")
  const [succeeded, setSucceeded] = useState(false)
  const mutation = useMutation({
    mutationFn: () =>
      operationsRequest(session, path, {
        method: "POST",
        body: JSON.stringify({
          auditNote: auditNote.trim() || undefined,
          environmentConfirmation: confirmation || undefined,
          idempotencyKey,
          expectedVersion,
        }),
        headers: { "Idempotency-Key": idempotencyKey },
      }),
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ["operations-overview", environment] })
      await queryClient.invalidateQueries({ queryKey: ["operations-route", environment] })
      setSucceeded(true)
      setOpen(false)
    },
  })
  const allowed =
    (!auditNoteRequired || auditNote.trim().length >= 8) &&
    (environment !== "prod" || confirmation === "PRODUCTION") &&
    Number.isSafeInteger(expectedVersion) &&
    idempotencyKey.length >= 8
  const versionUnavailable = !Number.isSafeInteger(expectedVersion)
  if (disabled || versionUnavailable)
    return (
      <Button
        variant="outline"
        size="sm"
        disabled
        title={disabledReason ?? (versionUnavailable ? "Version evidence is unavailable" : undefined)}
        aria-label={`${label} ${targetLabel ?? "action"}: ${disabledReason ?? (versionUnavailable ? "version evidence is unavailable" : "unavailable")}`}
      >
        {label}
      </Button>
    )
  return (
    <>
      <AlertDialog
        open={open}
        onOpenChange={(nextOpen) => {
          setOpen(nextOpen)
          if (nextOpen) {
            setAuditNote("")
            setConfirmation("")
            setIdempotencyKey(crypto.randomUUID())
            mutation.reset()
          }
        }}
      >
        <AlertDialogTrigger
          render={
            <Button
              variant={destructive ? "destructive" : "outline"}
              size="sm"
              aria-label={targetLabel ? `${label} ${targetLabel}` : label}
            />
          }
        >
          {label}
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle className="text-sm font-semibold">{label}?</AlertDialogTitle>
            <AlertDialogDescription className="mt-2 text-xs text-muted-foreground">
              This versioned operator action and its outcome are recorded in durable audit history.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <div className="grid gap-3 py-3">
            <Field>
              <FieldLabel htmlFor={`${fieldId}-audit`}>Operator Audit Note {auditNoteRequired ? "" : "(Optional)"}</FieldLabel>
              <Textarea
                id={`${fieldId}-audit`}
                value={auditNote}
                maxLength={280}
                onChange={(event) => setAuditNote(event.target.value)}
                placeholder="Explain why this action is required"
              />
              <FieldDescription>{auditNote.length} / 280</FieldDescription>
            </Field>
            {environment === "prod" ? (
              <Field>
                <FieldLabel htmlFor={`${fieldId}-confirm`}>Production Confirmation</FieldLabel>
                <Input
                  id={`${fieldId}-confirm`}
                  value={confirmation}
                  onChange={(event) => setConfirmation(event.target.value)}
                  placeholder="Type PRODUCTION"
                />
              </Field>
            ) : null}
            {mutation.isError ? (
              <p role="alert" className="text-xs text-destructive">
                <OperationsRequestError error={mutation.error} />
              </p>
            ) : null}
          </div>
          <AlertDialogFooter>
            <AlertDialogClose render={<Button variant="outline" />}>Cancel</AlertDialogClose>
            <Button disabled={!allowed || mutation.isPending} onClick={() => mutation.mutate()}>
              {mutation.isPending ? "Working…" : label}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
      {succeeded ? (
        <Toast
          title={`${label} Succeeded`}
          description={`${targetLabel ?? "Operator action"} was updated and fresh evidence was requested.`}
          tone="success"
          onClose={() => setSucceeded(false)}
        />
      ) : null}
    </>
  )
}
