/**
 * Heuristics for OAuth / session failures from oauth-client-browser and PDS writes.
 */

export function looksLikeStaleOAuthStorageError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const text = `${error.message}\n${String(error.cause ?? "")}`.toLowerCase();
  if (text.includes("deleted by another process")) return true;
  return false;
}

/** True when PDS writes likely failed for auth / scope / stale-session reasons. */
export function looksLikeOAuthScopeOrSessionError(error: unknown): boolean {
  if (looksLikeStaleOAuthStorageError(error)) return true;
  if (!(error instanceof Error)) return false;
  const msg = `${error.message} ${String(error.cause ?? "")}`.toLowerCase();
  if (msg.includes("no pds client")) return true;
  if (/\b401\b|\b403\b|\binvalid token\b|\bexpired\b/.test(msg)) return true;
  if (/\bunauthorized\b|\bforbidden\b|\bpermission\b|\bscope\b/.test(msg)) {
    return true;
  }
  const anyErr = error as { status?: number };
  const st = typeof anyErr.status === "number" ? anyErr.status : undefined;
  if (st === 401 || st === 403) return true;
  return false;
}
