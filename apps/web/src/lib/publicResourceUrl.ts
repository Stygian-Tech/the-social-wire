/**
 * URLs exposed to the browser (img, iframe, anchors) must avoid mixed content and
 * known-broken query payloads from federation tooling.
 */

/**
 * - Promotes `http:` to `https:` (PLC / Bridgy Fed often document `http://` PDS hosts).
 * - Removes `bridge_completed` (Bridgy Fed post-redirect noise that can break static permalinks).
 */
export function normalizeHttpUrlToHttps(raw: string): string {
  const s = raw.trim();
  try {
    const u = new URL(s);
    if (u.protocol === "http:") {
      u.protocol = "https:";
    }
    u.searchParams.delete("bridge_completed");
    // `new URL("https://host")` uses pathname `/`; `host` + `/xrpc` must not become `host//xrpc`.
    if (u.pathname === "/" && u.search === "" && u.hash === "") {
      return u.origin;
    }
    return u.href;
  } catch {
    if (/^http:\/\//i.test(s)) {
      const promoted = `https://${s.slice("http://".length)}`;
      try {
        const u2 = new URL(promoted);
        u2.searchParams.delete("bridge_completed");
        return u2.href;
      } catch {
        return promoted;
      }
    }
    return s;
  }
}

/**
 * Builds ordered `<img src>` candidates for entry rows: every value is HTTPS-normalized.
 * Never falls back from `https:` to `http:` — that triggers mixed-content warnings on HTTPS
 * app origins and does not help ATProto blob URLs.
 */
export function thumbnailImageSrcAttempts(
  primary?: string,
  fallback?: string
): string[] {
  const out: string[] = [];
  const push = (url: string) => {
    if (!out.includes(url)) out.push(url);
  };
  for (const raw of [primary, fallback]) {
    if (!raw?.trim()) continue;
    push(normalizeHttpUrlToHttps(raw.trim()));
  }
  return out;
}
