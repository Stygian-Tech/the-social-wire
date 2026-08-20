"use client"

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { useId, useState } from "react"
import { OperationsRequestError } from "@/components/operations/operations-request-error"
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
import { Field, FieldDescription, FieldGroup, FieldLabel } from "@/components/ui/field"
import { Input } from "@/components/ui/input"
import { Textarea } from "@/components/ui/textarea"
import { Toast } from "@/components/ui/toast"
import { useOperationsAuth } from "@/lib/auth-context"
import { ignoreGap } from "@/lib/operations-api"
import type { Gap } from "@/lib/operations-types"

export function ClearGapDialog({ gap, disabled = false }: { gap: Gap; disabled?: boolean }) {
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
      ignoreGap(session, {
        gap,
        auditNote: auditNote.trim(),
        environmentConfirmation: confirmation || undefined,
        idempotencyKey,
      }),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ["operations-overview", gap.environment] }),
        queryClient.invalidateQueries({ queryKey: ["operations-route", gap.environment] }),
      ])
      setSucceeded(true)
      setOpen(false)
    },
  })
  const allowed =
    auditNote.trim().length >= 8 &&
    (gap.environment !== "prod" || confirmation === "PRODUCTION") &&
    idempotencyKey.length >= 8 &&
    !mutation.isPending

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
              variant="destructive"
              size="sm"
              disabled={disabled}
              aria-label={`Clear legacy gap ${gap.id}`}
            />
          }
        >
          Clear Signal
        </AlertDialogTrigger>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Clear This Legacy V1 Signal?</AlertDialogTitle>
            <AlertDialogDescription>
              This marks the signal Ignored and moves it to History. It does not delete ingestion,
              recovery, or audit evidence.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <FieldGroup className="py-3">
            <Field>
              <FieldLabel htmlFor={`${fieldId}-audit`}>Operator Audit Note</FieldLabel>
              <Textarea
                id={`${fieldId}-audit`}
                value={auditNote}
                maxLength={280}
                onChange={(event) => setAuditNote(event.target.value)}
                placeholder="Explain why this legacy signal is no longer actionable"
              />
              <FieldDescription>{auditNote.length} / 280 · minimum 8 characters</FieldDescription>
            </Field>
            {gap.environment === "prod" ? (
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
          </FieldGroup>
          <AlertDialogFooter>
            <AlertDialogClose render={<Button variant="outline" />}>Cancel</AlertDialogClose>
            <Button variant="destructive" disabled={!allowed} onClick={() => mutation.mutate()}>
              {mutation.isPending ? "Clearing…" : "Clear Signal"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
      {succeeded ? (
        <Toast
          title="Legacy Signal Cleared"
          description="The signal was archived as Ignored and remains available in History."
          tone="success"
          onClose={() => setSucceeded(false)}
        />
      ) : null}
    </>
  )
}
