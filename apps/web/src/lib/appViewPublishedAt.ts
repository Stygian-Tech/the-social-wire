const FOUNDATION_REFERENCE_DATE_UNIX_SECONDS = 978_307_200;

/**
 * Normalizes AppView dates at the untyped JSON/cache boundary.
 *
 * Swift's default JSONEncoder represents Date as seconds since 2001. Supporting
 * that shape prevents a previously persisted malformed feed page from crashing
 * while the server's public contract remains an ISO 8601 string.
 */
export function normalizeAppViewPublishedAt(value: unknown): string {
  if (typeof value === "string") return value;

  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.toISOString() : "";
  }

  if (typeof value === "number" && Number.isFinite(value)) {
    const date = new Date(
      (value + FOUNDATION_REFERENCE_DATE_UNIX_SECONDS) * 1_000
    );
    return Number.isFinite(date.getTime()) ? date.toISOString() : "";
  }

  return "";
}
