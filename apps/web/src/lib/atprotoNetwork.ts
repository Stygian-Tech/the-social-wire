import { normalizeAppEnv, readAppEnvRaw } from "@/lib/appEnv";

export type AtprotoNetwork = {
  publicAppView: string;
  plcDirectory: string;
  handleResolver: string;
  appViewDid: string;
  chatServiceDid?: string;
  appLabelers?: string[];
};

const PUBLIC_APPVIEW = "https://public.api.bsky.app";
const PLC_DIRECTORY = "https://plc.directory";
const CHAT_SERVICE_DID = "did:web:api.bsky.chat";
const APPVIEW_DID = "did:web:api.bsky.app";

type LocalNetworkOverrides = {
  publicAppView?: string;
  plcDirectory?: string;
  handleResolver?: string;
  appViewDid?: string;
  chatServiceDid?: string;
  appLabelers?: string;
};

function httpsOrigin(value: string | undefined, fallback: string): string {
  if (!value?.trim()) return fallback;
  const url = new URL(value.trim());
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
    throw new Error("Local ATProto endpoints must be HTTPS origins.");
  }
  return url.origin;
}

/** Explicit local mode is required; hosted development and production ignore overrides. */
export function resolveAtprotoNetwork(appEnv: string, local: LocalNetworkOverrides = {}): AtprotoNetwork {
  if (normalizeAppEnv(appEnv) !== "local") {
    return { publicAppView: PUBLIC_APPVIEW, plcDirectory: PLC_DIRECTORY, handleResolver: PUBLIC_APPVIEW, appViewDid: APPVIEW_DID, chatServiceDid: CHAT_SERVICE_DID };
  }
  const publicAppView = httpsOrigin(local.publicAppView, PUBLIC_APPVIEW);
  const appViewDid = local.appViewDid?.trim() || APPVIEW_DID;
  if (!/^did:(plc:[a-z2-7]{24}|web:[^\s/?#]+)$/.test(appViewDid)) throw new Error("Invalid local AppView service DID.");
  const isolated = publicAppView !== PUBLIC_APPVIEW || appViewDid !== APPVIEW_DID;
  const chatServiceDid = local.chatServiceDid?.trim() || (isolated ? undefined : CHAT_SERVICE_DID);
  if (chatServiceDid && !/^did:(plc:[a-z2-7]{24}|web:[^\s/?#]+)$/.test(chatServiceDid)) throw new Error("Invalid local chat service DID.");
  const appLabelers = local.appLabelers === undefined ? undefined : local.appLabelers.split(",").map(did => did.trim()).filter(Boolean);
  if (appLabelers?.some(did => !/^did:(plc:[a-z2-7]{24}|web:[^\s/?#]+)$/.test(did))) throw new Error("Invalid local application labeler DID.");
  return {
    publicAppView,
    plcDirectory: httpsOrigin(local.plcDirectory, PLC_DIRECTORY),
    handleResolver: httpsOrigin(local.handleResolver, publicAppView),
    appViewDid,
    chatServiceDid,
    appLabelers,
  };
}

export function getAtprotoNetwork(): AtprotoNetwork {
  return resolveAtprotoNetwork(readAppEnvRaw(), {
    publicAppView: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APPVIEW_URL,
    plcDirectory: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_PLC_URL,
    handleResolver: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_HANDLE_RESOLVER_URL,
    chatServiceDid: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_CHAT_DID,
    appViewDid: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APPVIEW_DID,
    appLabelers: process.env.NEXT_PUBLIC_LOCAL_ATPROTO_APP_LABELERS,
  });
}

/** Keep the proxy DID and consent audiences aligned without altering production metadata. */
export function atprotoScopesForNetwork(scopes: string, network = getAtprotoNetwork()): string {
  const scoped = network.chatServiceDid ? scopes.replaceAll(`${CHAT_SERVICE_DID}%23bsky_chat`, `${network.chatServiceDid}%23bsky_chat`) : scopes.split(" ").filter(scope => !scope.includes(`${CHAT_SERVICE_DID}%23bsky_chat`)).join(" ");
  return scoped.replaceAll(`${APPVIEW_DID}%23bsky_appview`, `${network.appViewDid}%23bsky_appview`);
}

/** Compact local loopback scopes; the PDS requires identical strings in its metadata and PAR. */
export function localLoopbackOAuthScopes(scopes: string, appEnv = readAppEnvRaw()): string {
  if (normalizeAppEnv(appEnv) !== "local") return scopes;
  const compact = scopes.split(" ").map(scope => {
    if (!scope.startsWith("repo:") || !scope.includes("?")) return scope;
    const [resource, query] = scope.split("?", 2);
    const params = new URLSearchParams(query);
    const actions = new Set(params.getAll("action"));
    if (actions.size !== 3 || !["create", "update", "delete"].every(action => actions.has(action))) return scope;
    params.delete("action");
    const remaining = params.toString();
    return remaining ? `${resource}?${remaining}` : resource!;
  });
  // RPC scopes support repeated lxm values. Group only identical audiences:
  // this preserves exact permissions while keeping loopback client URLs bounded.
  const groups = new Map<string, string[]>();
  for (const scope of compact) {
    const match = /^rpc:([^?]+)\?aud=([^&]+)$/.exec(scope);
    if (match) { const methods = groups.get(match[2]) ?? []; methods.push(match[1]); groups.set(match[2], methods); }
  }
  const emitted = new Set<string>();
  return compact.flatMap(scope => {
    const match = /^rpc:([^?]+)\?aud=([^&]+)$/.exec(scope);
    if (!match || groups.get(match[2])!.length < 2) return [scope];
    if (emitted.has(match[2])) return [];
    emitted.add(match[2]);
    return [`rpc?aud=${match[2]}${groups.get(match[2])!.map(method => `&lxm=${method}`).join("")}`];
  }).join(" ");
}

/** Hosted metadata keeps full scope strings, including when a local HTTPS client is used. */
export function authorizationScopesForClient(scopes: string, clientId: string, appEnv = readAppEnvRaw()): string {
  return clientId.startsWith("http://localhost?") ? localLoopbackOAuthScopes(scopes, appEnv) : scopes;
}
