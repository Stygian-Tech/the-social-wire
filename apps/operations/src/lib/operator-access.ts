export function configuredOperatorDids(): Set<string> {
  return new Set(
    (process.env.NEXT_PUBLIC_OPERATIONS_OPERATOR_DIDS ?? "")
      .split(/[\s,]+/)
      .map((did) => did.trim())
      .filter(Boolean),
  )
}

export function isConfiguredOperatorDid(did: string): boolean {
  return configuredOperatorDids().has(did)
}

export function operatorAccessConfigured(): boolean {
  return configuredOperatorDids().size > 0
}
