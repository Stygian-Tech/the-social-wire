/**
 * Server-side probing of third-party framing policy (X-Frame-Options, CSP `frame-ancestors`).
 *
 * **Limitations:** CSP `frame-ancestors` parsing is intentionally conservative and incomplete — it
 * does not fully implement the CSP grammar (e.g. some quoted hosts, nonce-style edge cases). When
 * parsing is inconclusive after a restrictive-looking directive, prefer failing open so the client
 * still attempts the iframe (API errors already fail-soft in the UI). Duplicate CSP header fields
 * are reported as one comma-glued string from `Headers#get()` — comma-inside-directive ambiguity is
 * not resolved here.
 */

/** Lowercase hostnames (no port) that may embed the target when listed in `frame-ancestors`. */
export type ParseFramePolicyInput = {
  xFrameOptions: string | null | undefined;
  contentSecurityPolicy: string | null | undefined;
  embeddingHostHints: string[];
};

function normalizeHostHint(h: string): string {
  return h.trim().toLowerCase().replace(/^\[|\]$/g, "");
}

function stripCspQuotes(s: string): string {
  const t = s.trim();
  if ((t.startsWith("'") && t.endsWith("'")) || (t.startsWith('"') && t.endsWith('"'))) {
    return t.slice(1, -1);
  }
  return t;
}

export function ancestorHostFromCspToken(
  tok: string
): { scheme: string; host: string } | null {
  const clean = stripCspQuotes(tok);
  try {
    if (clean.startsWith("http://") || clean.startsWith("https://")) {
      const u = new URL(clean);
      return {
        scheme: u.protocol.replace(":", ""),
        host: normalizeHostHint(u.hostname),
      };
    }
  } catch {
    return null;
  }
  if (clean && !clean.includes(":/")) {
    const hostOnly = /^[a-z0-9._-]+$/i.test(clean)
      ? normalizeHostHint(clean)
      : null;
    if (hostOnly) {
      return { scheme: "https", host: hostOnly };
    }
  }
  return null;
}

/**
 * Returns whether a third-party page is likely frameable from our app, given response headers.
 * Conservative: `X-Frame-Options: DENY|SAMEORIGIN`, `frame-ancestors 'none'|'self'`, or an explicit
 * host list that does not mention any `embeddingHostHints` ⇒ not frameable.
 *
 * CSP keyword `'self'` is the **framed document’s** origin, not our app’s — it never counts as an
 * allow for cross-site embedding.
 */
export function parseFramePolicy(input: ParseFramePolicyInput): {
  frameable: boolean;
} {
  const hints = [
    ...new Set(
      input.embeddingHostHints.map(normalizeHostHint).filter(Boolean)
    ),
  ];

  const xfoRaw = input.xFrameOptions?.trim();
  const xfo = xfoRaw ? xfoRaw.split(/\s*,\s*/)[0]?.trim().toUpperCase() : "";
  if (xfo === "DENY" || xfo === "SAMEORIGIN") {
    return { frameable: false };
  }

  const cspMerged = normalizeCspHeaderValue(input.contentSecurityPolicy);
  if (!cspMerged) {
    return { frameable: true };
  }

  const faDirective = extractFrameAncestorsDirective(cspMerged);
  if (!faDirective) {
    return { frameable: true };
  }

  const tokens = tokenizeCspDirectiveValue(faDirective);
  if (tokens.length === 0) {
    return { frameable: true };
  }

  const lowered = tokens.map((t) => t.toLowerCase());

  if (lowered.includes("'none'")) {
    return { frameable: false };
  }

  if (lowered.some((t) => t === "*")) {
    return { frameable: true };
  }

  const ancestorHosts: Array<{ scheme: string; host: string }> = [];
  for (const tok of tokens) {
    const low = tok.toLowerCase();
    if (low === "'self'" || low === "*" || low === "'none'" || low === "data:" || low === "blob:") {
      continue;
    }
    const sh = ancestorHostFromCspToken(tok);
    if (sh) ancestorHosts.push(sh);
  }

  if (ancestorHosts.length === 0) {
    return { frameable: false };
  }

  if (hints.length === 0) {
    return { frameable: false };
  }

  for (const sh of ancestorHosts) {
    for (const hint of hints) {
      if (hostsMatchAncestor(hint, sh.host)) {
        return { frameable: true };
      }
    }
  }

  return { frameable: false };
}

/** Preserve `fetch` `Headers#get("Content-Security-Policy")` value with minimal rewriting. */
export function normalizeCspHeaderValue(
  raw: string | null | undefined
): string {
  if (raw == null) return "";
  return raw.trim();
}

export function validateHttpsEmbedProbeTarget(raw: string):
  | { ok: true; url: URL }
  | { ok: false } {
  try {
    const u = new URL(raw.trim());
    if (u.protocol !== "https:") return { ok: false };
    if (u.username || u.password) return { ok: false };
    const host = normalizeHostHint(u.hostname);
    if (!host || isBlockedEmbedProbeHostname(host)) return { ok: false };
    return { ok: true, url: u };
  } catch {
    return { ok: false };
  }
}

export function extractFrameAncestorsDirective(csp: string): string | null {
  const re = /\bframe-ancestors\b\s+([^;]*)/gi;
  const parts: string[] = [];
  let m: RegExpExecArray | null;
  while ((m = re.exec(csp)) !== null) {
    const chunk = m[1]?.trim();
    if (chunk) parts.push(chunk);
  }
  if (parts.length === 0) return null;
  return parts.join(" ");
}

export function tokenizeCspDirectiveValue(value: string): string[] {
  const out: string[] = [];
  let i = 0;
  const v = value.trim();
  while (i < v.length) {
    while (i < v.length && /\s/.test(v[i]!)) i++;
    if (i >= v.length) break;
    const start = i;
    if (v[i] === "'" || v[i] === '"') {
      const q = v[i]!;
      i++;
      while (i < v.length && v[i] !== q) i++;
      if (i < v.length) i++;
      out.push(v.slice(start, i));
      continue;
    }
    while (i < v.length && !/\s/.test(v[i]!)) i++;
    const tok = v.slice(start, i);
    if (tok) out.push(tok);
  }
  return out.filter(Boolean);
}

function hostsMatchAncestor(embeddingHint: string, ancestorHost: string): boolean {
  if (!embeddingHint || !ancestorHost) return false;
  if (embeddingHint === ancestorHost) return true;
  if (ancestorHost.startsWith(".")) {
    return (
      embeddingHint === ancestorHost.slice(1) ||
      embeddingHint.endsWith(ancestorHost)
    );
  }
  if (embeddingHint.endsWith("." + ancestorHost)) return true;
  return false;
}

function ipv4Parts(h: string): [number, number, number, number] | null {
  const re = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
  const m = re.exec(h);
  if (!m) return null;
  const a = Number(m[1]);
  const b = Number(m[2]);
  const c = Number(m[3]);
  const d = Number(m[4]);
  if ([a, b, c, d].some((x) => x > 255)) return null;
  return [a, b, c, d];
}

/** Hostnames blocked for SSRF-lite embed probing (localhost, RFC1918/link-local, `.local`). */
export function isBlockedEmbedProbeHostname(hostname: string): boolean {
  const h = hostname.trim().toLowerCase();
  if (!h) return true;
  if (h === "localhost") return true;
  if (h.endsWith(".localhost")) return true;
  if (h.endsWith(".local")) return true;

  if (h === "[::1]" || h === "::1") return true;

  const v4 = ipv4Parts(h);
  if (v4) {
    const [a, b] = v4;
    if (a === 127) return true;
    if (a === 0) return true;
    if (a === 10) return true;
    if (a === 192 && b === 168) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
  }

  const metadataLike =
    h.endsWith(".internal") ||
    h.endsWith(".lan") ||
    h === "metadata.google.internal" ||
    h.endsWith(".metadata.google.internal");
  if (metadataLike) return true;

  return false;
}
