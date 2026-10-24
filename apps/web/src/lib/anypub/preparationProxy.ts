const NSID = "at.anypub.prepare";
const MAX_BODY = 8 * 1024 * 1024;
const MAX_RESPONSE = 12 * 1024 * 1024;

class BodyLimitError extends Error {}
async function limitedBody(body: ReadableStream<Uint8Array> | null, limit: number): Promise<Uint8Array<ArrayBuffer>> {
  if (!body) return new Uint8Array();
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) { await reader.cancel(); throw new BodyLimitError(); }
      chunks.push(value);
    }
  } finally { reader.releaseLock(); }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.byteLength; }
  return result;
}
function error(status: number, message: string): Response {
  return Response.json({ error: status === 400 ? "InvalidRequest" : "PreparationUnavailable", message }, { status, headers: { "Cache-Control": "no-store" } });
}

/** Same-origin transport only. Browser OAuth/DPoP/cookie headers never reach AnyPub. */
export function createPreparationProxy(config: { upstream?: string; fetcher?: typeof fetch }) {
  return async function prepare(request: Request): Promise<Response> {
    if (!config.upstream) return error(503, "Configure ANYPUB_API_URL to enable article publishing.");
    if (request.headers.get("Content-Type")?.split(";")[0] !== "application/json") return error(415, "Expected application/json.");
    let endpoint: URL;
    try {
      const base = new URL(config.upstream);
      if (!['https:', 'http:'].includes(base.protocol) || base.username || base.password || base.search || base.hash) throw new Error();
      endpoint = new URL(`/xrpc/${NSID}`, base);
    } catch { return error(503, "The publishing service URL is invalid."); }
    let input: Uint8Array<ArrayBuffer>;
    try { input = await limitedBody(request.body, MAX_BODY); }
    catch (cause) { return error(cause instanceof BodyLimitError ? 413 : 400, "Invalid or oversized preparation input."); }
    try {
      const upstream = await (config.fetcher ?? fetch)(endpoint, {
        method: "POST", headers: { "Content-Type": "application/json" }, body: input,
        redirect: "error", credentials: "omit", cache: "no-store",
        signal: AbortSignal.any([request.signal, AbortSignal.timeout(30_000)]),
      });
      if (upstream.status !== 200 && ![400, 413, 415].includes(upstream.status)) return error(502, "The publishing preparation service is unavailable.");
      if (upstream.headers.get("Content-Type")?.split(";")[0] !== "application/json") return error(502, "The publishing service returned an invalid response.");
      const result = await limitedBody(upstream.body, MAX_RESPONSE);
      return new Response(result, { status: upstream.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
    } catch {
      return error(502, "The publishing preparation service is unavailable. Please retry.");
    }
  };
}
