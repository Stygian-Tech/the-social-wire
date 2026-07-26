const didPattern = /^did:[a-z0-9]+:[A-Za-z0-9._:%-]+$/

export function parseAuthorDids(value: string) {
  const tokens = value.split(/[\s,]+/).map((token) => token.trim()).filter(Boolean)
  const valid: string[] = []
  const invalid: string[] = []
  const seen = new Set<string>()

  for (const token of tokens) {
    if (!didPattern.test(token)) {
      invalid.push(token)
      continue
    }
    if (!seen.has(token)) {
      seen.add(token)
      valid.push(token)
    }
  }
  return { valid, invalid }
}
