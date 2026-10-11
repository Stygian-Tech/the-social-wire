type LocalOAuthEndpoints = { handleResolver?: string; plcDirectory?: string }

function httpsOrigin(value: string | undefined, fallback: string): string {
  if (!value?.trim()) return fallback
  const url = new URL(value)
  if (url.protocol !== "https:" || url.username || url.password || url.pathname !== "/" || url.search || url.hash)
    throw new Error("Local OAuth Endpoints Must Be HTTPS Origins.")
  return url.origin
}

/** Sandbox discovery is opt-in and usable only from a loopback browser surface. */
export function operationsOAuthNetwork(hostname: string, local: LocalOAuthEndpoints = {}) {
  if (!["localhost", "127.0.0.1"].includes(hostname))
    return { handleResolver: "https://bsky.social", plcDirectoryUrl: "https://plc.directory" }
  return {
    handleResolver: httpsOrigin(local.handleResolver, "https://bsky.social"),
    plcDirectoryUrl: httpsOrigin(local.plcDirectory, "https://plc.directory"),
  }
}
