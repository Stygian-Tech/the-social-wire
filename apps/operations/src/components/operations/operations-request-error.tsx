import { OperationsHttpError } from "@/lib/operations-api"

export function operationsErrorText(error: unknown) {
  const message = error instanceof Error ? error.message : "The Operations request failed."
  if (!(error instanceof OperationsHttpError)) return message
  const retryGuidance = error.retryAfter
    ? ` Retry-After: ${error.retryAfter}. Wait for the server-defined retry window before trying again.`
    : ""
  return `HTTP ${error.status}: ${message}${retryGuidance}`
}

export function OperationsRequestError({ error }: { error: unknown }) {
  const message = error instanceof Error ? error.message : "The Operations request failed."
  const httpError = error instanceof OperationsHttpError ? error : undefined
  return (
    <>
      <span>{httpError ? `HTTP ${httpError.status}: ${message}` : message}</span>
      {httpError?.retryAfter ? (
        <span className="mt-1 block">
          Retry-After: {httpError.retryAfter}. Wait for the server-defined retry window before trying again.
        </span>
      ) : null}
    </>
  )
}
