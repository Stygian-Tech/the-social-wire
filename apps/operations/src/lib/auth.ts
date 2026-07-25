import {
  BrowserOAuthClient,
  OAuthResponseError,
  TokenInvalidError,
  TokenRefreshError,
  TokenRevokedError,
  type OAuthSession,
} from "@atproto/oauth-client-browser"
import { buildAtprotoLoopbackClientId } from "@atproto/oauth-types"
import { operationsOAuthClientMetadataUrl } from "@/lib/operations-oauth-client-metadata"

export const OPERATIONS_OAUTH_SCOPE = "atproto"
const storedDidKey = "@@atproto/oauth-client-browser(sub)"
let clientPromise: Promise<BrowserOAuthClient> | undefined
type SessionInvalidationListener = (did: string, cause: unknown) => void
const sessionInvalidationListeners = new Set<SessionInvalidationListener>()

function notifySessionInvalidated(did: string, cause: unknown) {
  window.localStorage.removeItem(storedDidKey)
  sessionInvalidationListeners.forEach((listener) => listener(did, cause))
}

export function onOAuthSessionInvalidated(listener: SessionInvalidationListener) {
  sessionInvalidationListeners.add(listener)
  return () => {
    sessionInvalidationListeners.delete(listener)
  }
}

export function isTerminalOAuthSessionError(error: unknown) {
  return (
    error instanceof TokenRefreshError ||
    error instanceof TokenRevokedError ||
    error instanceof TokenInvalidError ||
    (error instanceof OAuthResponseError && error.status === 400)
  )
}

function isLocal() {
  return typeof window !== "undefined" && ["localhost", "127.0.0.1"].includes(window.location.hostname)
}
function localCallback() {
  const url = new URL(window.location.href)
  url.hostname = "127.0.0.1"
  url.pathname = "/callback"
  url.search = ""
  url.hash = ""
  return url.toString()
}
function hostedCallback() {
  return new URL("/callback", window.location.origin).toString()
}
function clientId() {
  if (isLocal())
    return buildAtprotoLoopbackClientId({ redirect_uris: [localCallback()], scope: OPERATIONS_OAUTH_SCOPE })
  const gatewayOrigin = process.env.NEXT_PUBLIC_OPERATIONS_GATEWAY_ORIGIN?.trim()
  if (gatewayOrigin) return operationsOAuthClientMetadataUrl(gatewayOrigin)
  return `${window.location.origin}/operations-client-metadata.json`
}

export function getOAuthClient() {
  if (!clientPromise)
    clientPromise = BrowserOAuthClient.load({
      clientId: clientId(),
      handleResolver: "https://bsky.social",
      responseMode: isLocal() ? "query" : "fragment",
      onDelete: (did, cause) => notifySessionInvalidated(did, cause),
    })
  return clientPromise
}

export async function restoreSession(): Promise<OAuthSession | null> {
  try {
    return (await (await getOAuthClient()).initRestore())?.session ?? null
  } catch {
    return null
  }
}

export async function beginSignIn(handle: string) {
  await (await getOAuthClient()).signInRedirect(handle, { scope: OPERATIONS_OAUTH_SCOPE })
}

export async function finishSignIn(): Promise<OAuthSession> {
  const hash = new URLSearchParams(window.location.hash.slice(1))
  const query = new URLSearchParams(window.location.search)
  const params = hash.has("state") ? hash : query
  const client = await getOAuthClient()
  const redirect = client.findRedirectUrl() ?? (isLocal() ? localCallback() : hostedCallback())
  return (await client.initCallback(params, redirect as Parameters<BrowserOAuthClient["initCallback"]>[1])).session
}

export async function endSession(did: string) {
  try {
    await (await getOAuthClient()).revoke(did)
  } finally {
    window.localStorage.removeItem(storedDidKey)
  }
}

export async function authFetch(session: OAuthSession, url: string, init?: RequestInit) {
  try {
    return await session.fetchHandler(url, init)
  } catch (error) {
    if (isTerminalOAuthSessionError(error)) notifySessionInvalidated(session.did, error)
    throw error
  }
}
export type { OAuthSession }
