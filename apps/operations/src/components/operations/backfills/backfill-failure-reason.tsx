export function BackfillFailureReason({ reason, className }: { reason?: string; className?: string }) {
  if (!reason) return null

  return (
    <span role="alert" className={`block ${className ?? ""}`}>
      Failure Reason: {reason.replaceAll("_", " ")}
    </span>
  )
}
