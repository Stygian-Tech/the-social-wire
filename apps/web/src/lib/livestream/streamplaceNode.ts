export const HOSTED_STREAMPLACE = "https://stream.place";
/** Public browser requests only. No PDS OAuth token is sent to a node. */
export function streamplaceNodeOrigin(value: string): string {
  const url = new URL(value.trim());
  const host = url.hostname.toLowerCase();
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash || !host.includes(".") || /^[\d.]+$/.test(host) || host.includes(":") || ["localhost", "local", "test", "internal", "invalid"].some(suffix => host === suffix || host.endsWith(`.${suffix}`))) throw new Error("Use a public HTTPS Streamplace node origin.");
  return url.origin;
}
export function streamplacePublicUrl(node: string, path: string): string { return new URL(path, streamplaceNodeOrigin(node)).href; }
export async function streamplacePublicJSON(node: string, path: string, signal?: AbortSignal): Promise<unknown> {
  const response = await fetch(streamplacePublicUrl(node, path), { signal, credentials: "omit", redirect: "error", headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`Streamplace request failed (${response.status}).`);
  return response.json();
}
